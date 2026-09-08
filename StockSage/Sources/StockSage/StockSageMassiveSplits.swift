import Foundation

/// Current endpoint and SDK: massive.com/docs/rest/stocks/corporate-actions/splits,
/// client-python massive/rest/reference.py:list_stocks_splits. Execution-day trades
/// already use post-split units (including premarket). Only US price/share basis;
/// not cash-in-lieu, mergers, spinoffs, broker reconciliation or a trading signal.
@MainActor enum StockSageMassiveSplits {
    struct RefreshKey: Equatable {
        let trades: [TradeRecord]
        let refreshedAt: Date?
    }
    nonisolated struct Event: Sendable, Equatable {
        let id: String
        let day: String
        let multiplier: Double // new shares / old shares, not the cumulative historical factor
    }
    nonisolated struct Snapshot: Sendable, Equatable {
        let symbol: String
        let fromDay: String
        let throughDay: String
        let checkedAt: Date
        let events: [Event]

        func covers(since: Date, now: Date) -> Bool {
            guard let from = StockSageMassiveSplits.day(since), let today = StockSageMassiveSplits.day(now) else { return false }
            let age = now.timeIntervalSince(checkedAt)
            return age.isFinite && age >= 0 && age < 86_400 && from >= fromDay && throughDay == today
        }
    }
    nonisolated struct Basis: Sendable {
        let trade: TradeRecord?
        let multiplier: Double?
        let note: String?
        var needsCloseReconciliation: Bool { multiplier.map { $0 != 1 } ?? false }
        var allowsMarkPrefill: Bool { trade != nil && multiplier == 1 }
        static func unavailable(_ reason: String) -> Self {
            .init(trade: nil, multiplier: nil, note: "Split basis unverified — \(reason). P&L and level verdict withheld.")
        }
    }
    private nonisolated enum Failure: Error { case invalidPayload }
    private nonisolated static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")!
        f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        return f
    }()
    nonisolated static func day(_ date: Date) -> String? {
        guard date.timeIntervalSince1970.isFinite else { return nil }
        return formatter.string(from: date)
    }
    private nonisolated static func validDay(_ text: String) -> Bool {
        guard text.count == 10, let date = formatter.date(from: text) else { return false }
        return formatter.string(from: date) == text
    }

    nonisolated static func request(symbol: String, since: Date, now: Date, key: String) -> URLRequest? {
        guard StockSageMassive.covers(symbol), !key.isEmpty, since <= now,
              let from = day(since), from >= "1978-10-25", let through = day(now),
              var parts = URLComponents(string: StockSageMassive.host + "/stocks/v1/splits") else { return nil }
        parts.queryItems = [.init(name: "ticker", value: symbol.uppercased()),
            .init(name: "execution_date.gte", value: from), .init(name: "execution_date.lte", value: through),
            .init(name: "sort", value: "execution_date.asc"), .init(name: "limit", value: "100")]
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// ponytail: one complete page/100 events per open symbol. Partial or malformed results
    /// withhold comparisons; add bounded pagination only if real portfolios reach this ceiling.
    nonisolated static func parse(_ data: Data, symbol: String, since: Date, now: Date) throws -> Snapshot {
        guard data.count <= 2_000_000, since <= now, let from = day(since), from >= "1978-10-25", let through = day(now),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "OK", let raw = root["results"] as? [Any], raw.count <= 100 else { throw Failure.invalidPayload }
        if let next = root["next_url"], !(next is NSNull) {
            guard let text = next as? String, text.isEmpty else { throw Failure.invalidPayload }
        }
        var events: [String: Event] = [:]
        var days: Set<String> = []
        for value in raw {
            guard let row = value as? [String: Any], row["ticker"] as? String == symbol.uppercased(),
                  let id = row["id"] as? String, !id.isEmpty, id.utf8.count <= 256,
                  let date = row["execution_date"] as? String, validDay(date), date >= from, date <= through,
                  let kind = row["adjustment_type"] as? String,
                  let old = StockSageMassive.finite(row["split_from"]), old > 0,
                  let new = StockSageMassive.finite(row["split_to"]), new > 0 else { throw Failure.invalidPayload }
            let factor = new / old
            guard factor.isFinite, factor > 0,
                  (kind == "forward_split" && factor > 1) || (kind == "reverse_split" && factor < 1)
                    || (kind == "stock_dividend" && factor > 1) else { throw Failure.invalidPayload }
            let event = Event(id: id, day: date, multiplier: factor)
            if let previous = events[id] {
                guard previous == event else { throw Failure.invalidPayload }
                continue
            }
            // Two different IDs on one date may be duplicate representations, not two splits.
            // Do not multiply an ambiguous corporate action twice.
            guard days.insert(date).inserted else { throw Failure.invalidPayload }
            events[id] = event
        }
        return Snapshot(symbol: symbol.uppercased(), fromDay: from, throughDay: through, checkedAt: now,
                        events: events.values.sorted { $0.day < $1.day })
    }

    nonisolated static func comparison(_ original: TradeRecord, snapshot: Snapshot?, markAsOf: Date?, now: Date) -> Basis {
        guard let snapshot, snapshot.symbol == original.symbol.uppercased(), snapshot.covers(since: original.openedAt, now: now) else {
            return .unavailable("no current complete corporate-action check")
        }
        guard original.isOpen, original.openedAt <= now,
              original.entry > 0, original.entry.isFinite, original.stop > 0, original.stop.isFinite,
              original.shares > 0, original.shares.isFinite,
              original.target.map({ $0 > 0 && $0.isFinite }) ?? true,
              let entryDay = day(original.openedAt), let markAsOf, markAsOf >= original.openedAt, markAsOf <= now,
              !StockSageQuoteFreshness.isStale(symbol: original.symbol, marketTime: markAsOf, asOf: now),
              let markDay = day(markAsOf) else { return .unavailable("invalid terms or missing, stale or pre-entry price") }
        // Same execution-day entries are already post-split. Only strictly later events apply.
        let applied = snapshot.events.filter { $0.day > entryDay }
        guard applied.allSatisfy({ $0.day <= markDay }) else { return .unavailable("the price predates an executed split") }
        var factor = 1.0
        for event in applied {
            factor *= event.multiplier
            guard factor > 0, factor.isFinite else { return .unavailable("invalid combined ratio") }
        }
        var copy = original
        if factor != 1 { copy.rebase(dividingBy: factor) }
        guard copy.entry > 0, copy.entry.isFinite, copy.stop > 0, copy.stop.isFinite,
              copy.shares > 0, copy.shares.isFinite, copy.target.map({ $0 > 0 && $0.isFinite }) ?? true else {
            return .unavailable("adjusted values overflow")
        }
        let note = applied.isEmpty ? nil : String(format: "split-adjusted ×%.8g · Massive · checked %@ · comparison only; journal unchanged",
                                                  factor, snapshot.throughDay)
        return .init(trade: copy, multiplier: factor, note: note)
    }

    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
    private static var unavailableUntil: Date?

    static func fetch(symbol: String, since: Date, now: Date) async -> Snapshot? {
        guard ToolPolicy.isExternalAllowed, !Task.isCancelled,
              unavailableUntil.map({ now >= $0 }) ?? true,
              let request = request(symbol: symbol, since: since, now: now, key: StockSageMassive.apiKey),
              let (data, response) = try? await session.data(for: request),
              ToolPolicy.isExternalAllowed, !Task.isCancelled, let http = response as? HTTPURLResponse else { return nil }
        if [401, 402, 403].contains(http.statusCode) { unavailableUntil = now.addingTimeInterval(86_400) }
        guard http.statusCode == 200 else { return nil }
        return try? parse(data, symbol: symbol, since: since, now: now)
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
