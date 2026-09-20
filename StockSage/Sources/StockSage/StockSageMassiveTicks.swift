import Foundation
import CoreFoundation

/// On-demand SIP tape and bounded paper-price fallback. Never called by the board sweep.
/// https://massive.com/docs/rest/stocks/trades-quotes/trades: price, decimal_size/size,
/// exchange, id, sip_timestamp (ns), sequence_number, tape, conditions, trf_id.
/// https://massive.com/docs/rest/stocks/trades-quotes/quotes: bid/ask_price/size/exchange,
/// sip_timestamp (ns), sequence_number. Both expose results[] and next_url.
/// https://massive.com/docs/rest/stocks/market-operations/exchanges: id, mic, acronym.
@MainActor
enum StockSageMassiveTicks {
    nonisolated static let pageLimit = 3
    nonisolated static let rowsPerPage = 100
    nonisolated static let maximumBytes = 1_000_000
    typealias CapturedAccess = (key: String, isCurrent: @Sendable () -> Bool)

    nonisolated enum Kind: String, Sendable, CaseIterable { case trades, quotes }
    nonisolated struct Trade: Sendable, Equatable {
        let price: Double
        let size: Double
        let exchange: Int64?
        let timestamp: Date
        let sequence: Int64?
        var conditions: [Int64]? = nil
        var participantTime: Date? = nil
        var correction: Int64? = nil
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

    // Internal so offline regressions can seed/restore the existing cache without provider I/O.
    static var exchangeCache: (at: Date, values: [Int64: Exchange], isCurrent: @Sendable () -> Bool)?
    static var tradeReferenceCache: (at: Date, bytes: Data, isCurrent: @Sendable () -> Bool)?

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
                let rawConditions = row["conditions"] as? [Any]
                let conditions = rawConditions?.compactMap { StockSageMassive.int64($0) }
                let participant = StockSageMassive.int64(row["participant_timestamp"])
                    .flatMap { $0 > 0 ? StockSageMassive.date(fromNanoseconds: $0) : nil }
                page.trades.append(.init(price: price, size: size, exchange: StockSageMassive.int64(row["exchange"]),
                    timestamp: at, sequence: sequence,
                    conditions: conditions?.count == rawConditions?.count ? conditions : nil,
                    participantTime: participant,
                    correction: row["correction"] == nil ? 0 : StockSageMassive.int64(row["correction"])))
            case .quotes:
                // Optional/missing sides are unavailable, never synthetic liquidity.
                let bid = row["bid_price"] == nil ? 0 : StockSageMassive.finite(row["bid_price"])
                let ask = row["ask_price"] == nil ? 0 : StockSageMassive.finite(row["ask_price"])
                let bs = row["bid_size"] == nil ? 0 : StockSageMassive.finite(row["bid_size"])
                let az = row["ask_size"] == nil ? 0 : StockSageMassive.finite(row["ask_size"])
                guard let bid, bid >= 0, let ask, ask >= 0, let bs, bs >= 0, let az, az >= 0 else {
                    page.rejected += 1; continue
                }
                var quote = StockSageNBBO(symbol: symbol.uppercased(), bid: bid, ask: ask, bidSize: bs, askSize: az,
                                         bidExchange: StockSageMassive.int64(row["bid_exchange"]),
                                         askExchange: StockSageMassive.int64(row["ask_exchange"]),
                                         timestamp: at, sequence: sequence)
                func codes(_ raw: Any?) -> [Int64]? {
                    guard let raw = raw as? [Any] else { return nil }
                    let values = raw.compactMap { StockSageMassive.int64($0) }
                    return values.count == raw.count && values.allSatisfy { $0 >= 0 } ? values : nil
                }
                quote.conditions = codes(row["conditions"])
                quote.indicators = row["indicators"] == nil ? [] : codes(row["indicators"])
                quote.participantTime = StockSageMassive.int64(row["participant_timestamp"])
                    .flatMap { $0 > 0 ? StockSageMassive.date(fromNanoseconds: $0) : nil }
                page.quotes.append(quote)
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

    static func exchanges(now: Date = Date(), access: StockSageMassive.Access = .init(),
                          transport: StockSageMassive.Transport? = nil,
                          bypassCache: Bool = false) async throws -> [Int64: Exchange] {
        let captured = access.capture()
        guard captured.isCurrent() else { throw Failure.unavailable }
        if !bypassCache, transport == nil, let cache = exchangeCache, cache.isCurrent(),
           (0..<86_400).contains(now.timeIntervalSince(cache.at)) { return cache.values }
        guard let url = URL(string: StockSageMassive.host + "/v3/reference/exchanges?asset_class=stocks&locale=us"),
              let request = authorized(url, key: captured.key) else { throw Failure.unavailable }
        let values = try parseExchanges(await data(for: request, captured: captured, transport: transport))
        guard captured.isCurrent() else { throw Failure.unavailable }
        if transport == nil { exchangeCache = (now, values, captured.isCurrent) }
        return values
    }

    /// Only a complete, unambiguous reference can qualify a cost observation.
    /// https://massive.com/docs/rest/stocks/market-operations/condition-codes
    nonisolated static func parseRegularQuoteConditions(_ data: Data) throws -> Set<Int64> {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "OK", root["next_url"] == nil,
              let rows = root["results"] as? [[String: Any]], rows.count <= 1_000 else { throw Failure.invalidPayload }
        var seen: Set<Int64> = []
        var regular: Set<Int64> = []
        for row in rows {
            guard let id = StockSageMassive.int64(row["id"]), id >= 0,
                  seen.insert(id).inserted else { throw Failure.invalidPayload }
            guard row["asset_class"] as? String == "stocks",
                  (row["data_types"] as? [String])?.contains("quote") == true,
                  row["type"] as? String == "quote_condition", row["legacy"] == nil || row["legacy"] as? Bool == false,
                  row["exchange"] == nil,
                  (row["sip_mapping"] as? [String: String])?["UTP"] == "R" else { continue }
            regular.insert(id)
        }
        return regular
    }

    static func regularQuoteConditions(access: StockSageMassive.Access = .init(),
        transport: StockSageMassive.Transport? = nil) async throws -> Set<Int64> {
        let captured = access.capture()
        guard let url = URL(string: StockSageMassive.host + "/v3/reference/conditions?asset_class=stocks&data_type=quote&limit=1000"),
              let request = authorized(url, key: captured.key) else { throw Failure.unavailable }
        return try parseRegularQuoteConditions(await data(for: request, captured: captured, transport: transport))
    }

    /// Ordinary last prices follow the provider's consolidated price-update rules, not the
    /// separate quote-condition or paper-simulation policies. Unknown/mixed conditions fail closed.
    /// https://massive.com/docs/rest/stocks/market-operations/condition-codes
    nonisolated static func parseDisplayTradeConditions(_ data: Data) throws -> Set<Int64> {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "OK", root["next_url"] == nil,
              let rows = root["results"] as? [[String: Any]], rows.count <= 1_000 else { throw Failure.invalidPayload }
        var seen: Set<Int64> = [], allowed: Set<Int64> = []
        for row in rows {
            guard let id = StockSageMassive.int64(row["id"]), id >= 0,
                  seen.insert(id).inserted else { throw Failure.invalidPayload }
            guard row["asset_class"] as? String == "stocks",
                  (row["data_types"] as? [String])?.contains("trade") == true,
                  row["legacy"] == nil || row["legacy"] as? Bool == false, row["exchange"] == nil,
                  let rules = row["update_rules"] as? [String: Any],
                  let consolidated = rules["consolidated"] as? [String: Any],
                  let updates = consolidated["updates_open_close"] as? NSNumber,
                  CFGetTypeID(updates) == CFBooleanGetTypeID(), updates.boolValue else { continue }
            allowed.insert(id)
        }
        guard !allowed.isEmpty else { throw Failure.invalidPayload }
        return allowed
    }

    nonisolated static func qualifiesDisplayTrade(conditions: [Int64]?, allowed: Set<Int64>,
                                                   sip: Date, participant: Date?) -> Bool {
        guard let conditions, !conditions.isEmpty, conditions.allSatisfy(allowed.contains),
              sip.timeIntervalSince1970.isFinite else { return false }
        // Snapshot schema provides SIP time only. When the participant clock is supplied,
        // a newly reported old trade must not refresh an ordinary current-price observation.
        if let participant {
            guard (0...StockSageLiveStream.maximumLiveAge).contains(sip.timeIntervalSince(participant)) else { return false }
        }
        return true
    }

    static func displayTradeConditions(access: StockSageMassive.Access = .init(),
        transport: StockSageMassive.Transport? = nil, bypassCache: Bool = false) async throws -> Set<Int64> {
        try await displayTradeConditions(captured: access.capture(), transport: transport, bypassCache: bypassCache)
    }

    static func displayTradeConditions(captured: CapturedAccess,
        transport: StockSageMassive.Transport? = nil, bypassCache: Bool = false) async throws -> Set<Int64> {
        try parseDisplayTradeConditions(await tradeReference(captured: captured, transport: transport, bypassCache: bypassCache))
    }

    private static func tradeReference(captured: CapturedAccess,
        transport: StockSageMassive.Transport?, bypassCache: Bool = false) async throws -> Data {
        guard captured.isCurrent() else { throw Failure.unavailable }
        let now = Date()
        if !bypassCache, transport == nil, let cache = tradeReferenceCache, cache.isCurrent(),
           (0..<86_400).contains(now.timeIntervalSince(cache.at)) { return cache.bytes }
        guard let url = URL(string: StockSageMassive.host + "/v3/reference/conditions?asset_class=stocks&data_type=trade&limit=1000"),
              let request = authorized(url, key: captured.key) else { throw Failure.unavailable }
        let bytes = try await data(for: request, captured: captured, transport: transport)
        // Only a complete parsed reference is cached. Each consumer applies its own eligibility.
        _ = try parseDisplayTradeConditions(bytes)
        if transport == nil { tradeReferenceCache = (now, bytes, captured.isCurrent) }
        return bytes
    }

    nonisolated static func researchQuote(_ page: Page, symbol: String,
        regularConditions: Set<Int64>, at now: Date) -> StockSageNBBO? {
        guard page.rejected == 0, let timestamp = page.quotes.map(\.timestamp).max() else { return nil }
        var tied: [StockSageNBBO] = []
        for quote in page.quotes where quote.timestamp == timestamp {
            if !tied.contains(quote) { tied.append(quote) }
        }
        guard tied.allSatisfy({ $0.matches(symbol) }), var latest = tied.first else { return nil }
        if tied.count > 1 {
            // Conflicting payloads need explicit sequence ordering; page order proves nothing.
            let sequences = tied.compactMap(\.sequence)
            guard sequences.count == tied.count, sequences.allSatisfy({ $0 >= 0 }),
                  Set(sequences).count == tied.count else { return nil }
            latest = tied.max(by: { $0.sequence! < $1.sequence! })!
        }
        let quote = latest.qualifyingCosts(regularConditions: regularConditions)
        // Never search backwards for an older usable side after a withdrawal or condition change.
        return quote.costConditionVerified && quote.spreadBps(at: now) != nil ? quote : nil
    }

    /// One current quote page. A partial older tape is irrelevant to the latest observation.
    static func freshResearchNBBO(symbol: String, regularConditions: Set<Int64>,
        access: StockSageMassive.Access = .init(), transport: StockSageMassive.Transport? = nil) async -> StockSageNBBO? {
        let captured = access.capture()
        let now = Date(), from = Date().addingTimeInterval(-10)
        guard !regularConditions.isEmpty, let request = request(kind: .quotes, symbol: symbol,
            from: from, to: now, key: captured.key) else { return nil }
        do {
            let bytes = try await data(for: request, captured: captured, transport: transport)
            guard !Task.isCancelled, bytes.count <= 1_000_000 else { return nil }
            return researchQuote(try parse(bytes, kind: .quotes, symbol: symbol, from: from, to: now),
                symbol: symbol, regularConditions: regularConditions, at: Date())
        } catch { return nil }
    }

    /// Conservative simulation eligibility, resolved by reference names, never guessed numeric IDs.
    /// Form T and odd lots can be timely observations even though they do not update official OHLC.
    nonisolated static func parsePaperTradeConditions(_ data: Data) throws -> Set<Int64> {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "OK", root["next_url"] == nil,
              let rows = root["results"] as? [[String: Any]], rows.count <= 1_000 else { throw Failure.invalidPayload }
        let names: Set<String> = ["Regular Sale", "Automatic Execution", "Intermarket Sweep",
            "Form T/Extended Hours", "Odd Lot Trade", "Trade Thru Exempt"]
        var seen: Set<Int64> = [], allowed: Set<Int64> = []
        for row in rows {
            guard let id = StockSageMassive.int64(row["id"]), id >= 0,
                  seen.insert(id).inserted else { throw Failure.invalidPayload }
            guard row["asset_class"] as? String == "stocks",
                  (row["data_types"] as? [String])?.contains("trade") == true,
                  row["legacy"] == nil || row["legacy"] as? Bool == false, row["exchange"] == nil,
                  let name = row["name"] as? String, names.contains(name) else { continue }
            allowed.insert(id)
        }
        guard !allowed.isEmpty else { throw Failure.invalidPayload }
        return allowed
    }

    nonisolated static func eligiblePaperTrades(_ trades: [Trade], allowed: Set<Int64>, now: Date) -> [Trade] {
        trades.filter { trade in
            guard let conditions = trade.conditions, !conditions.isEmpty,
                  conditions.allSatisfy(allowed.contains), trade.correction == 0,
                  let participant = trade.participantTime, participant <= trade.timestamp,
                  (0...120).contains(now.timeIntervalSince(participant)),
                  (0...120).contains(now.timeIntervalSince(trade.timestamp)),
                  trade.price.isFinite, trade.price > 0, trade.size.isFinite, trade.size > 0 else { return false }
            return true
        }.sorted {
            // REST arrives SIP-descending. Participant ties must not select the older report.
            if $0.participantTime != $1.participantTime { return $0.participantTime! < $1.participantTime! }
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return max(-1, $0.sequence ?? -1) < max(-1, $1.sequence ?? -1)
        }
    }

    static func paperQuote(_ trades: [Trade], symbol: String, allowed: Set<Int64>,
                           now: Date) -> StockSageQuoteService.LiveQuote? {
        guard StockSageMassive.covers(symbol),
              let trade = eligiblePaperTrades(trades, allowed: allowed, now: now).last else { return nil }
        // No previous-close claim is supplied by a tick. Research retains its daily-bar inputs.
        return .init(symbol: symbol, price: trade.price, previousClose: trade.price,
                     marketTime: trade.participantTime, isNewListing: true,
                     massiveTradeSequence: trade.sequence, priceSource: .massiveSIP, paperTradeQualified: true)
    }

    static func freshPaperQuote(symbol: String, now: Date = Date(),
        access: StockSageMassive.Access = .init(), transport: StockSageMassive.Transport? = nil) async -> StockSageQuoteService.LiveQuote? {
        let captured = access.capture()
        guard let trade = await freshPaperTrades(symbol: symbol, now: now, captured: captured, transport: transport).last,
              captured.isCurrent() else { return nil }
        return .init(symbol: symbol, price: trade.price, previousClose: trade.price,
                     marketTime: trade.participantTime, isNewListing: true,
                     massiveTradeSequence: trade.sequence, priceSource: .massiveSIP, paperTradeQualified: true)
    }

    private static func freshPaperTrades(symbol: String, now: Date, captured: CapturedAccess,
        transport: StockSageMassive.Transport?) async -> [Trade] {
        do {
            let allowed = try parsePaperTradeConditions(await tradeReference(captured: captured, transport: transport))
            guard captured.isCurrent() else { return [] }
            let from = now.addingTimeInterval(-120)
            guard let request = request(kind: .trades, symbol: symbol, from: from, to: now,
                                        key: captured.key) else { return [] }
            let page = try parse(await data(for: request, captured: captured, transport: transport),
                                 kind: .trades, symbol: symbol, from: from, to: now)
            guard captured.isCurrent() else { return [] }
            return eligiblePaperTrades(page.trades, allowed: allowed, now: Date())
        } catch { return [] }
    }

    /// Dated intraday evidence, never fed into the daily indicator engine as if it were days.
    nonisolated struct Minute: Codable, Sendable, Equatable {
        let at: Date
        let open: Double
        let high: Double
        let low: Double
        let close: Double
        let volume: Double
    }
    nonisolated struct Intraday: Sendable {
        let facts: [String]
        let asOf: Date
        var maximumAge: TimeInterval = 180
        var bars: [Minute] = []
        var verifiedMinutes = false
        var missingMinutes: Int {
            guard let first = bars.first, let last = bars.last else { return 0 }
            let seconds = last.at.timeIntervalSince(first.at)
            guard (0...12_000).contains(seconds) else { return 0 }
            return max(0, Int(seconds / 60) + 1 - bars.count)
        }
        func fresh(at now: Date) -> Bool { (0...maximumAge).contains(now.timeIntervalSince(asOf)) }
    }
    nonisolated static func parseIntradayFacts(_ data: Data, symbol: String, from: Date, now: Date) -> Intraday? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "OK", root["ticker"] as? String == symbol,
              root["next_url"] == nil, let rows = root["results"] as? [[String: Any]], rows.count <= 200 else { return nil }
        var bars: [Minute] = []
        var seen: Set<Int64> = []
        for row in rows {
            guard let ms = StockSageMassive.int64(row["t"]), ms > 0, ms % 60_000 == 0,
                  seen.insert(ms).inserted,
                  let o = StockSageMassive.finite(row["o"]), o > 0,
                  let h = StockSageMassive.finite(row["h"]), h >= o,
                  let l = StockSageMassive.finite(row["l"]), l > 0, l <= o,
                  let c = StockSageMassive.finite(row["c"]), c >= l, c <= h,
                  let v = StockSageMassive.finite(row["v"]), v >= 0 else { return nil }
            let at = Date(timeIntervalSince1970: Double(ms) / 1_000)
            guard at >= from, at.addingTimeInterval(60) <= now else { continue }
            bars.append(.init(at: at, open: o, high: h, low: l, close: c, volume: v))
        }
        bars.sort { $0.at < $1.at }
        guard bars.count >= 2, let first = bars.first, let last = bars.last,
              (0...180).contains(now.timeIntervalSince(last.at.addingTimeInterval(60))) else { return nil }
        let facts = ["Intraday evidence: \(bars.count) completed one-minute Massive bars from \(first.at.ISO8601Format()) through \(last.at.addingTimeInterval(60).ISO8601Format()). Missing minutes are not filled; no claim of continuous liquidity."]
            + bars.suffix(5).map { "Completed minute starting \($0.at.ISO8601Format()): open \($0.open), high \($0.high), low \($0.low), close \($0.close) USD; volume \($0.volume) shares." }
        let adjusted = (root["adjusted"] as? NSNumber).map {
            CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue
        } == true
        return Intraday(facts: facts, asOf: last.at.addingTimeInterval(60), bars: bars,
            verifiedMinutes: adjusted && StockSageMassive.int64(root["resultsCount"]) == Int64(rows.count))
    }

    static func intradayFacts(symbol: String, from: Date, now: Date,
        access: StockSageMassive.Access = .init(), transport: StockSageMassive.Transport? = nil) async -> Intraday? {
        let captured = access.capture()
        guard captured.isCurrent(), StockSageMassive.covers(symbol), from < now,
              let fromNS = nanoseconds(from), let toNS = nanoseconds(now),
              let lower = Int64(fromNS), let upper = Int64(toNS),
              let url = URL(string: StockSageMassive.host + "/v2/aggs/ticker/\(symbol)/range/1/minute/\(lower / 1_000_000)/\(upper / 1_000_000)?adjusted=true&sort=asc&limit=200"),
              let request = authorized(url, key: captured.key) else { return nil }
        if let data = try? await data(for: request, captured: captured, transport: transport),
           let bars = parseIntradayFacts(data, symbol: symbol, from: from, now: now) { return bars }
        guard captured.isCurrent() else { return nil }
        let trades = await freshPaperTrades(symbol: symbol, now: Date(), captured: captured, transport: transport)
            .filter { ($0.participantTime ?? .distantPast) >= from }
        return captured.isCurrent() ? intradayTradeFacts(trades, now: Date()) : nil
    }

    /// Input must already pass eligiblePaperTrades; these are observations, not synthetic candles.
    nonisolated static func intradayTradeFacts(_ eligible: [Trade], now: Date) -> Intraday? {
        let trades = eligible.filter { trade in
            guard let at = trade.participantTime else { return false }
            return (0...120).contains(now.timeIntervalSince(at))
        }.sorted { $0.participantTime! < $1.participantTime! }
        guard Set(trades.compactMap(\.participantTime)).count >= 2, let last = trades.last else { return nil }
        let facts = ["Recent completed minute candles unavailable. Intraday fallback: \(trades.count) individually qualified SIP trades in a bounded two-minute tape. These are NOT OHLC candles, a complete volume census, executable quotes or proof of liquidity."]
            + trades.suffix(5).map { "Qualified trade at \($0.participantTime!.ISO8601Format()): price \($0.price) USD; individual trade size \($0.size) shares." }
        return Intraday(facts: facts, asOf: last.participantTime!, maximumAge: 120)
    }

    static func fetch(symbol: String, from: Date, to: Date, access: StockSageMassive.Access = .init(),
                      transport: StockSageMassive.Transport? = nil) async -> Tape {
        var tape = Tape()
        let captured = access.capture()
        let key = captured.key
        for kind in Kind.allCases {
            guard var request = request(kind: kind, symbol: symbol, from: from, to: to, key: key) else {
                tape.notices.append(Failure.unavailable.localizedDescription); break
            }
            var visited: Set<String> = []
            for pageIndex in 0..<pageLimit {
                do {
                    try Task.checkCancellation()
                    if let url = request.url?.absoluteString { visited.insert(url) }
                    let page = try parse(await data(for: request, captured: captured, transport: transport), kind: kind, symbol: symbol, from: from, to: to)
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
            if !captured.isCurrent() { return Tape(notices: [Failure.unavailable.localizedDescription]) }
        }
        return captured.isCurrent() ? tape : Tape(notices: [Failure.unavailable.localizedDescription])
    }

    private static func data(for request: URLRequest, captured: CapturedAccess,
                             transport: StockSageMassive.Transport?) async throws -> Data {
        guard captured.isCurrent() else { throw Failure.unavailable }
        let (data, response) = try await StockSageMassive.response(for: request, maximumBytes: maximumBytes, transport: transport)
        guard captured.isCurrent() else { throw Failure.unavailable }
        guard response.statusCode == 200 else { throw Failure.http(response.statusCode) }
        return data
    }
}
