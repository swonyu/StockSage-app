import Foundation

/// On-tap cited news, never a trading/ranking signal. Massive first, EODHD fallback.
/// https://massive.com/docs/rest/stocks/news — GET /v2/reference/news; ticker,
/// published_utc.gte/lte (also verified in the official Python SDK), order/sort/limit.
/// results[]: published_utc, title, description, article_url, publisher.name, tickers,
/// insights[].ticker/sentiment/sentiment_reasoning. The feed updates hourly, NOT live.
/// One bounded request per Explain, plus at most one fallback. No pagination/polling;
/// this is a selection, never a complete news census. EODHD's existing single-symbol
/// news fallback spends 10 API credits per request (see HANDOFF.md).
enum StockSageNewsService {

    nonisolated struct NewsItem: Sendable, Equatable, Identifiable {
        let date: Date
        let title: String
        /// 1-2 sentence snippet derived from the vendor's full `content` field — never the whole
        /// body (a long or paywalled article body is not something this app is licensed to show).
        let snippet: String
        let link: URL?
        /// EODHD's own sentiment polarity, when the payload carries one. Nil is common (most rows
        /// omit it) and is not an error.
        let sentiment: Double?
        let source: String
        /// Provider commentary for THIS ticker, not a prediction or verified app fact.
        let insight: String?

        init(date: Date, title: String, snippet: String, link: URL?, sentiment: Double?,
             source: String = "EODHD news", insight: String? = nil) {
            self.date = date; self.title = title; self.snippet = snippet; self.link = link
            self.sentiment = sentiment; self.source = source; self.insight = insight
        }

        nonisolated var id: String { "\(date.timeIntervalSince1970)|\(title)" }
    }

    nonisolated static let caveat =
        "Selected news excerpts and provider sentiment are not verified analysis or trading signals. "
        + "Absence here is not evidence that nothing happened."

    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)

    /// Recent news for a US symbol, newest first, within the freshness cutoff (`maxAgeDays`).
    /// `[]` — never throws — when external access is off, the symbol is not US-covered
    /// or both providers are unavailable. An empty result never means "no news exists".
    static func recentNews(for symbol: String, limit: Int = 5, maxAgeDays: Double = 7,
                           now: Date = Date()) async -> [NewsItem] {
        guard ToolPolicy.isExternalAllowed, !Task.isCancelled,
              validBounds(limit, maxAgeDays, now), StockSageMassive.covers(symbol) else { return [] }
        return await firstAvailable(massive: {
            guard let req = massiveRequest(symbol: symbol, key: StockSageMassive.apiKey,
                                           limit: limit, maxAgeDays: maxAgeDays, now: now),
                  let data = await get(req) else { return [] }
            return parseMassiveNews(data, symbol: symbol, limit: limit, maxAgeDays: maxAgeDays, now: now)
        }, fallback: {
            await eodhdNews(for: symbol, limit: limit, maxAgeDays: maxAgeDays, now: now)
        })
    }

    /// A missing key, error or empty usable selection falls through. No second call on success.
    static func firstAvailable(massive: () async -> [NewsItem],
                               fallback: () async -> [NewsItem]) async -> [NewsItem] {
        guard !Task.isCancelled else { return [] }
        let items = await massive()
        guard !Task.isCancelled else { return [] }
        return items.isEmpty ? await fallback() : items
    }

    private static func eodhdNews(for symbol: String, limit: Int, maxAgeDays: Double, now: Date) async -> [NewsItem] {
        guard ToolPolicy.isExternalAllowed, !Task.isCancelled, StockSageEODHD.covers(symbol) else { return [] }
        let key = StockSageEODHD.apiKey
        guard !key.isEmpty, var parts = URLComponents(string: "https://eodhd.com/api/news") else { return [] }
        parts.queryItems = [.init(name: "s", value: StockSageEODHD.eodhdSymbol(symbol)),
                            .init(name: "limit", value: String(limit)), .init(name: "api_token", value: key),
                            .init(name: "fmt", value: "json")]
        guard let url = parts.url,
              let data = await get(URLRequest(url: url, timeoutInterval: 12)),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return parseNews(raw, limit: limit, maxAgeDays: maxAgeDays, now: now)
    }

    private static func get(_ request: URLRequest) async -> Data? {
        guard ToolPolicy.isExternalAllowed, !Task.isCancelled,
              let (data, response) = try? await session.data(for: request),
              !Task.isCancelled, ToolPolicy.isExternalAllowed,
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_000_000 else { return nil }
        return data
    }

    nonisolated static func massiveRequest(symbol: String, key: String, limit: Int = 5,
                                          maxAgeDays: Double = 7, now: Date = Date()) -> URLRequest? {
        guard StockSageMassive.covers(symbol), !key.isEmpty, validBounds(limit, maxAgeDays, now),
              var parts = URLComponents(string: StockSageMassive.host + "/v2/reference/news") else { return nil }
        let iso = ISO8601DateFormatter()
        parts.queryItems = [.init(name: "ticker", value: symbol.uppercased()),
                            .init(name: "published_utc.gte", value: iso.string(from: now.addingTimeInterval(-maxAgeDays * 86_400))),
                            .init(name: "published_utc.lte", value: iso.string(from: now)),
                            .init(name: "order", value: "desc"), .init(name: "sort", value: "published_utc"),
                            .init(name: "limit", value: String(limit))]
        guard let url = parts.url else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return req
    }

    nonisolated static func parseMassiveNews(_ data: Data, symbol: String, limit: Int = 5,
                                            maxAgeDays: Double = 7, now: Date = Date()) -> [NewsItem] {
        guard validBounds(limit, maxAgeDays, now), StockSageMassive.covers(symbol), data.count <= 2_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] == nil || root["status"] as? String == "OK",
              let rows = root["results"] as? [[String: Any]], rows.count <= 1_000 else { return [] }
        let items = rows.compactMap { row -> NewsItem? in
            guard let tickers = row["tickers"] as? [String], tickers.contains(symbol.uppercased()),
                  let date = recentDate(row["published_utc"], maxAgeDays: maxAgeDays, now: now),
                  let rawTitle = row["title"] as? String else { return nil }
            let title = boundedText(rawTitle, limit: 240)
            guard !title.isEmpty else { return nil }
            let publisher = boundedText((row["publisher"] as? [String: Any])?["name"] as? String ?? "", limit: 80)
            let insights = (row["insights"] as? [[String: Any]] ?? []).compactMap { value -> String? in
                guard value["ticker"] as? String == symbol.uppercased(),
                      let label = value["sentiment"] as? String, ["positive", "negative", "neutral"].contains(label),
                      let text = value["sentiment_reasoning"] as? String else { return nil }
                let reason = boundedText(text, limit: 360)
                return reason.isEmpty ? nil : "\(label) — \(reason)"
            }
            let unique = Set(insights)
            return NewsItem(date: date, title: title, snippet: snippet(from: row["description"] as? String ?? ""),
                            link: safeLink(row["article_url"]), sentiment: nil,
                            source: "Massive news · \(publisher.isEmpty ? "publisher unavailable" : publisher)",
                            insight: unique.count == 1 ? unique.first : nil)
        }
        return selection(items, limit: limit)
    }

    /// Pure parse of the vendor's array-of-objects payload — no network, unit-testable. Skips any
    /// row missing a usable date or title, and drops rows older than `maxAgeDays`.
    nonisolated static func parseNews(_ raw: [[String: Any]], limit: Int = 5, maxAgeDays: Double = 7,
                                      now: Date = Date()) -> [NewsItem] {
        guard validBounds(limit, maxAgeDays, now), raw.count <= 1_000 else { return [] }
        var out: [NewsItem] = []
        for row in raw {
            guard let date = recentDate(row["date"], maxAgeDays: maxAgeDays, now: now),
                  let rawTitle = row["title"] as? String else { continue }
            let title = boundedText(rawTitle, limit: 240)
            guard !title.isEmpty else { continue }
            let link = safeLink(row["link"])
            let sentimentObj = row["sentiment"] as? [String: Any]
            let sentiment = (sentimentObj?["polarity"] as? Double)
                ?? (sentimentObj?["polarity"] as? Int).map(Double.init)
            out.append(NewsItem(date: date, title: title,
                                snippet: snippet(from: row["content"] as? String ?? ""),
                                link: link, sentiment: sentiment.flatMap { $0.isFinite ? $0 : nil }))
        }
        return selection(out, limit: limit)
    }

    private nonisolated static func validBounds(_ limit: Int, _ days: Double, _ now: Date) -> Bool {
        (1...5).contains(limit) && days.isFinite && (0...7).contains(days) && now.timeIntervalSince1970.isFinite
    }

    private nonisolated static func recentDate(_ raw: Any?, maxAgeDays: Double, now: Date) -> Date? {
        guard let text = raw as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = iso.date(from: text) ?? ISO8601DateFormatter().date(from: text),
              date >= now.addingTimeInterval(-maxAgeDays * 86_400), date <= now else { return nil }
        return date
    }

    private nonisolated static func safeLink(_ raw: Any?) -> URL? {
        guard let text = raw as? String, text.utf8.count <= 2_048,
              let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private nonisolated static func selection(_ items: [NewsItem], limit: Int) -> [NewsItem] {
        var seen: Set<String> = []
        return Array(items.sorted { $0.date == $1.date ? $0.title < $1.title : $0.date > $1.date }
            .filter { seen.insert($0.id).inserted }.prefix(limit))
    }

    /// Whole-word cap: never turn a truncated price/identifier into a different numeric fact.
    private nonisolated static func boundedText(_ text: String, limit: Int) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        var kept = ""
        for word in words {
            let next = kept.isEmpty ? String(word) : "\(kept) \(word)"
            guard next.count <= limit else { return kept.isEmpty ? "" : kept + "…" }
            kept = next
        }
        return kept
    }

    /// 1-2 sentence truncation of a full article body — splits on ". " and keeps at most 2
    /// sentences. Pure and deterministic so a test can pin exact output.
    nonisolated static func snippet(from content: String) -> String {
        let trimmed = boundedText(content, limit: 500)
        guard !trimmed.isEmpty else { return "" }
        let sentences = trimmed.components(separatedBy: ". ")
        let kept = sentences.prefix(2).joined(separator: ". ")
        if sentences.count <= 2 { return kept }
        return kept.hasSuffix(".") ? kept : kept + "."
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
