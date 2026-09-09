import Foundation
import CryptoKit

/// On-tap cited news, never a trading/ranking signal. Massive; EODHD is disabled.
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
        /// Original validated provider timestamp preserves its timezone and fractional precision.
        let publicationTime: String?
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
        private let articleIdentity: String?

        init(date: Date, title: String, snippet: String, link: URL?, sentiment: Double?,
             source: String = "EODHD news", insight: String? = nil, articleIdentity: String? = nil, publicationTime: String? = nil) {
            self.date = date; self.title = title; self.snippet = snippet; self.link = link
            self.sentiment = sentiment; self.source = source; self.insight = insight
            self.articleIdentity = articleIdentity
            self.publicationTime = publicationTime
        }

        nonisolated var id: String { articleIdentity ?? "\(date.timeIntervalSince1970)|\(title)|\(snippet)|\(source)|\(link?.absoluteString ?? "")|\(insight ?? "")|\(sentiment.map { String($0) } ?? "")" }
    }

    nonisolated static let caveat =
        "Selected news excerpts and provider sentiment are not verified analysis or trading signals. "
        + "Absence here is not evidence that nothing happened."

    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)

    nonisolated enum Provider: String, Sendable, Equatable { case massive = "Massive", eodhd = "EODHD" }
    nonisolated enum Failure: String, Sendable, Equatable {
        case policyDenied = "external access off", cancelled, unsupported, invalidBounds = "invalid bounds"
        case missingKey = "missing key", transport, http, malformed, oversized
        case providerDisabled = "provider disabled"
    }
    nonisolated enum Status: Sendable, Equatable {
        case answered
        case unavailable(Failure)
        case notChecked(Failure)
    }
    /// Counts only: discarded provider text is never retained as diagnostics or source evidence.
    nonisolated struct Excluded: Sendable, Equatable {
        var stale = 0
        var future = 0
        var missingDate = 0
        var invalid = 0
    }
    nonisolated struct Attempt: Sendable, Equatable {
        let provider: Provider
        let checkedAt: Date
        let status: Status
        var items: [NewsItem] = []
        var excluded = Excluded()
    }
    nonisolated struct Observation: Sendable, Equatable {
        /// At most two attempts, in request order. Empty primary still triggers the existing fallback.
        let attempts: [Attempt]
        var withholdingReason: Failure? = nil
        var items: [NewsItem] { withholdingReason == nil ? attempts.last?.items ?? [] : [] }
        var summary: String {
            attempts.map { attempt in
                let state: String
                switch attempt.status {
                case .answered:
                    state = "answered; selected \(attempt.items.count) usable excerpts"
                        + "; excluded stale \(attempt.excluded.stale), future \(attempt.excluded.future), missing/invalid date \(attempt.excluded.missingDate), other invalid \(attempt.excluded.invalid)"
                case .unavailable(let reason): state = "unavailable (\(reason.rawValue))"
                case .notChecked(let reason): state = "not checked (\(reason.rawValue))"
                }
                let timeLabel: String
                if case .notChecked = attempt.status { timeLabel = "recorded" } else { timeLabel = "checked" }
                return "\(attempt.provider.rawValue): \(state); \(timeLabel) \(StockSageNewsService.instant(attempt.checkedAt))."
            }.joined(separator: " ")
                + (withholdingReason.map { " Evidence withheld (\($0.rawValue))." } ?? "")
                + " This bounded selection is not a news census; zero usable excerpts does not mean no news."
        }
    }

    /// Stored Date in UTC at millisecond precision; parsed articles retain their original timestamp too.
    nonisolated static func instant(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Compatibility for array callers; migrate to `observation` to retain check outcomes.
    static func recentNews(for symbol: String, limit: Int = 5, maxAgeDays: Double = 7,
                           now: Date = Date()) async -> [NewsItem] {
        await observation(for: symbol, limit: limit, maxAgeDays: maxAgeDays, now: now).items
    }

    static func observation(for symbol: String, limit: Int = 5, maxAgeDays: Double = 7,
                            now: Date = Date()) async -> Observation {
        await observe(for: symbol, limit: limit, maxAgeDays: maxAgeDays, now: now,
            allowed: { ToolPolicy.isExternalAllowed }, clock: { Date() }, request: { provider in
                switch provider {
                case .massive:
                    return massiveRequest(symbol: symbol, key: StockSageMassive.apiKey,
                                          limit: limit, maxAgeDays: maxAgeDays, now: now)
                case .eodhd:
                    return eodhdRequest(symbol: symbol, key: StockSageEODHD.apiKey, limit: limit)
                }
            }, transport: { try await session.data(for: $0) })
    }

    /// Shared production request/parser/fallback boundary. Fakes inject requests, policy and transport;
    /// tests never consult credentials, global settings or authenticated endpoints.
    static func observe(for symbol: String, limit: Int = 5, maxAgeDays: Double = 7, now: Date,
                        allowed: () -> Bool, clock: () -> Date,
                        request: (Provider) -> URLRequest?,
                        transport: (URLRequest) async throws -> (Data, URLResponse)) async -> Observation {
        func blocked() -> Failure? {
            if Task.isCancelled { return .cancelled }
            return allowed() ? nil : .policyDenied
        }
        if let reason = blocked() {
            return Observation(attempts: [.init(provider: .massive, checkedAt: clock(), status: .notChecked(reason))])
        }
        guard validBounds(limit, maxAgeDays, now), StockSageMassive.covers(symbol) else {
            return Observation(attempts: [.init(provider: .massive, checkedAt: clock(),
                status: .notChecked(validBounds(limit, maxAgeDays, now) ? .unsupported : .invalidBounds))])
        }
        var attempts: [Attempt] = []
        for provider in [Provider.massive, .eodhd] {
            if let reason = blocked() {
                attempts.append(.init(provider: provider, checkedAt: clock(), status: .notChecked(reason)))
                break
            }
            guard provider != .eodhd || StockSageEODHD.covers(symbol) else {
                attempts.append(.init(provider: provider, checkedAt: clock(), status: .notChecked(.unsupported)))
                break
            }
            guard let req = request(provider) else {
                let reason: Failure = provider == .eodhd && !StockSageEODHD.isEnabled ? .providerDisabled : .missingKey
                attempts.append(.init(provider: provider, checkedAt: clock(), status: .notChecked(reason)))
                continue
            }
            // Recheck after request construction too; no transport starts after permission revocation.
            if let reason = blocked() {
                attempts.append(.init(provider: provider, checkedAt: clock(), status: .notChecked(reason)))
                break
            }
            do {
                let (data, response) = try await transport(req)
                if let reason = blocked() {
                    attempts.append(.init(provider: provider, checkedAt: clock(), status: .unavailable(reason)))
                    break
                }
                let attempt: Attempt
                if (response as? HTTPURLResponse)?.statusCode != 200 {
                    attempt = .init(provider: provider, checkedAt: clock(), status: .unavailable(.http))
                } else {
                    attempt = parseObservation(data, provider: provider, symbol: symbol, limit: limit,
                                               maxAgeDays: maxAgeDays, now: now, checkedAt: clock())
                }
                attempts.append(attempt)
                if !attempt.items.isEmpty { break }
            } catch {
                let reason = blocked() ?? .transport
                attempts.append(.init(provider: provider, checkedAt: clock(), status: .unavailable(reason)))
                if reason == .cancelled || reason == .policyDenied { break }
            }
        }
        return Observation(attempts: attempts)
    }

    /// Compatibility seam for older callers/tests; production uses typed attempts above.
    static func firstAvailable(massive: () async -> [NewsItem],
                               fallback: () async -> [NewsItem]) async -> [NewsItem] {
        guard !Task.isCancelled else { return [] }
        let items = await massive()
        guard !Task.isCancelled else { return [] }
        if !items.isEmpty { return items }
        let result = await fallback()
        return Task.isCancelled ? [] : result
    }

    nonisolated static func eodhdRequest(symbol: String, key: String, limit: Int) -> URLRequest? {
        guard StockSageEODHD.isEnabled, StockSageEODHD.covers(symbol), !key.isEmpty, (1...5).contains(limit),
              var parts = URLComponents(string: "https://eodhd.com/api/news") else { return nil }
        parts.queryItems = [.init(name: "s", value: StockSageEODHD.eodhdSymbol(symbol)),
                            .init(name: "limit", value: String(limit)), .init(name: "api_token", value: key),
                            .init(name: "fmt", value: "json")]
        guard let url = parts.url else { return nil }
        return URLRequest(url: url, timeoutInterval: 12)
    }

    nonisolated static func parseObservation(_ data: Data, provider: Provider, symbol: String,
                                            limit: Int = 5, maxAgeDays: Double = 7, now: Date,
                                            checkedAt: Date) -> Attempt {
        func failed(_ reason: Failure) -> Attempt {
            .init(provider: provider, checkedAt: checkedAt, status: .unavailable(reason))
        }
        guard validBounds(limit, maxAgeDays, now) else { return failed(.invalidBounds) }
        guard data.count <= 2_000_000 else { return failed(.oversized) }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return failed(.malformed) }
        let rows: [[String: Any]]
        switch provider {
        case .massive:
            guard let root = json as? [String: Any],
                  root["status"] == nil || root["status"] as? String == "OK",
                  let values = root["results"] as? [[String: Any]] else { return failed(.malformed) }
            rows = values
        case .eodhd:
            guard let values = json as? [[String: Any]] else { return failed(.malformed) }
            rows = values
        }
        guard rows.count <= 1_000 else { return failed(.oversized) }
        var excluded = Excluded()
        for row in rows {
            guard let date = publicationDate(row[provider == .massive ? "published_utc" : "date"]) else {
                excluded.missingDate += 1; continue
            }
            if date.instant > Decimal(now.timeIntervalSince1970) { excluded.future += 1; continue }
            if date.instant < Decimal(now.addingTimeInterval(-maxAgeDays * 86_400).timeIntervalSince1970) {
                excluded.stale += 1; continue
            }
            if boundedText(row["title"] as? String ?? "", limit: 240).isEmpty
                || (provider == .massive && !(row["tickers"] as? [String] ?? []).contains(symbol.uppercased())) {
                excluded.invalid += 1
            }
        }
        let items = provider == .massive
            ? parseMassiveNews(data, symbol: symbol, limit: limit, maxAgeDays: maxAgeDays, now: now)
            : parseNews(rows, limit: limit, maxAgeDays: maxAgeDays, now: now)
        return Attempt(provider: provider, checkedAt: checkedAt, status: .answered, items: items, excluded: excluded)
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
                            insight: unique.count == 1 ? unique.first : nil, articleIdentity: identity(row, provider: .massive), publicationTime: row["published_utc"] as? String)
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
                                link: link, sentiment: sentiment.flatMap { $0.isFinite ? $0 : nil },
                                articleIdentity: identity(row, provider: .eodhd), publicationTime: row["date"] as? String))
        }
        return selection(out, limit: limit)
    }

    private nonisolated static func validBounds(_ limit: Int, _ days: Double, _ now: Date) -> Bool {
        (1...5).contains(limit) && days.isFinite && (0...7).contains(days) && now.timeIntervalSince1970.isFinite
    }

    private nonisolated static func recentDate(_ raw: Any?, maxAgeDays: Double, now: Date) -> Date? {
        guard let date = publicationDate(raw),
              date.instant >= Decimal(now.addingTimeInterval(-maxAgeDays * 86_400).timeIntervalSince1970),
              date.instant <= Decimal(now.timeIntervalSince1970) else { return nil }
        return date.date
    }

    private nonisolated struct Publication {
        let date: Date
        let instant: Decimal
    }

    private nonisolated static func publicationDate(_ raw: Any?) -> Publication? {
        guard let text = raw as? String, text.utf8.count <= 100,
              text.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})\z"#,
                         options: .regularExpression) != nil else { return nil }
        guard let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text)) else { return nil }
        // Compare provider fractions exactly: Date rounds nanoseconds and can turn a future
        // publication into equality at the cutoff. The original timestamp stays unchanged.
        let tail = text.dropFirst(19)
        let fraction = tail.prefix { $0 != "Z" && $0 != "+" && $0 != "-" }
        let wholeText = String(text.prefix(19)) + tail.dropFirst(fraction.count)
        guard let whole = try? Date.ISO8601FormatStyle().parse(wholeText) else { return nil }
        let instant = Decimal(whole.timeIntervalSince1970)
            + (Decimal(string: "0" + fraction, locale: Locale(identifier: "en_US_POSIX")) ?? 0)
        return Publication(date: date, instant: instant)
    }

    nonisolated static func safeLink(_ raw: Any?) -> URL? {
        guard let text = raw as? String, text.utf8.count <= 2_048,
              let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// Digest exact provider records BEFORE excerpt truncation. Never merge a revision whose
    /// changed number/sign lands beyond a display cap, nor collapse different attributions.
    private nonisolated static func identity(_ row: [String: Any], provider: Provider) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return nil }
        return provider.rawValue + ":" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func selection(_ items: [NewsItem], limit: Int) -> [NewsItem] {
        var seen: Set<String> = []
        return Array(items.sorted { $0.date == $1.date ? $0.title < $1.title : $0.date > $1.date }
            .filter { seen.insert($0.id).inserted }.prefix(limit))
    }

    /// Whole-word cap: never turn a truncated price/identifier into a different numeric fact.
    nonisolated static func boundedText(_ text: String, limit: Int) -> String {
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
