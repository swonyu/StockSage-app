import Foundation
import CoreFoundation
import CryptoKit

/// Direct Benzinga news only; no credential reads, fallback routing or persistent cache.
/// Official contracts (2026-09-09): docs.benzinga.com/api-reference/authentication and
/// /api-reference/news-api/get-news-items. Header-only live support is UNVERIFIED:
/// auth guidance recommends Authorization: token KEY; the news schema requires query token.
/// Never retry with a URL credential. The owner tests the header contract privately.
@MainActor
enum StockSageBenzingaNews {
    nonisolated static let provider = "Benzinga direct"
    nonisolated static let maximumBytes = 2_000_000
    nonisolated static let maximumRecords = 20

    nonisolated enum Failure: String, Error, Sendable, Equatable {
        case policyDenied, cancelled, configurationChanged, missingKey, invalidRequest
        case unauthorized, forbidden, throttled, http, transport, redirect, malformed, oversized
    }
    nonisolated enum Status: Sendable, Equatable {
        case answered
        case unavailable(Failure)
        case notChecked(Failure)
    }
    nonisolated struct Excluded: Sendable, Equatable {
        var stale = 0
        var future = 0
        var missingDate = 0
        var invalid = 0
        var unrelated = 0
        var duplicates = 0
        var omitted = 0
    }
    nonisolated struct Record: Sendable, Equatable {
        let newsItem: StockSageNewsService.NewsItem
        let providerID: String
        /// Exact validated provider strings. Checked time is never publication/update time.
        let originalCreated: String
        let originalUpdated: String?
        let updatedAt: Date?
        /// A headline-only record is valid. Missing body is not a parse failure.
        let hasBody: Bool
    }
    nonisolated struct Observation: Sendable, Equatable {
        let checkedAt: Date
        let status: Status
        var records: [Record] = []
        var excluded = Excluded()
        var retryAfter: TimeInterval? = nil
        var items: [StockSageNewsService.NewsItem] { records.map(\.newsItem) }
    }

    /// One page of ticker-filtered abstracts; no full archive/body request or URL key.
    nonisolated static func request(symbol: String, key: String, limit: Int = 5,
                                     maxAgeDays: Double = 7, now: Date = Date()) -> URLRequest? {
        guard validBounds(symbol, limit, maxAgeDays, now), validKey(key),
              var parts = URLComponents(string: "https://api.benzinga.com/api/v2/news") else { return nil }
        parts.queryItems = [URLQueryItem(name: "page", value: "0"),
            .init(name: "pageSize", value: String(limit)), .init(name: "displayOutput", value: "abstract"),
            .init(name: "tickers", value: symbol.uppercased()), .init(name: "sort", value: "created:desc"),
            .init(name: "publishedSince", value: String(Int(now.addingTimeInterval(-maxAgeDays * 86_400).timeIntervalSince1970.rounded(.down))))]
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("token \(key)", forHTTPHeaderField: "Authorization")
        request.httpShouldHandleCookies = false
        return request
    }

    /// The caller captures its credential generation; no key or generation enters source evidence.
    static func fetch(symbol: String, key: String, limit: Int = 5, maxAgeDays: Double = 7,
                      now: Date = Date(), isCurrent: () -> Bool) async -> Observation {
        await observe(symbol: symbol, key: key, limit: limit, maxAgeDays: maxAgeDays, now: now,
            allowed: { ToolPolicy.isExternalAllowed }, isCurrent: isCurrent, clock: { Date() },
            transport: { try await send($0, allowed: { ToolPolicy.isExternalAllowed }, isCurrent: isCurrent) })
    }

    /// Injectable boundary: offline tests do not read Keychain, defaults or provider credentials.
    static func observe(symbol: String, key: String, limit: Int = 5, maxAgeDays: Double = 7, now: Date,
                        allowed: () -> Bool, isCurrent: () -> Bool, clock: () -> Date,
                        transport: (URLRequest) async throws -> (Data, URLResponse)) async -> Observation {
        if let reason = blocked(allowed, isCurrent) { return .init(checkedAt: clock(), status: .notChecked(reason)) }
        guard !key.isEmpty else { return .init(checkedAt: clock(), status: .notChecked(.missingKey)) }
        guard let request = request(symbol: symbol, key: key, limit: limit, maxAgeDays: maxAgeDays, now: now) else {
            return .init(checkedAt: clock(), status: .notChecked(.invalidRequest))
        }
        if let reason = blocked(allowed, isCurrent) { return .init(checkedAt: clock(), status: .notChecked(reason)) }
        do {
            let (data, response) = try await transport(request)
            if let reason = blocked(allowed, isCurrent) { return .init(checkedAt: clock(), status: .unavailable(reason)) }
            guard let http = response as? HTTPURLResponse else { return .init(checkedAt: clock(), status: .unavailable(.transport)) }
            guard http.url == request.url else { return .init(checkedAt: clock(), status: .unavailable(.redirect)) }
            guard http.statusCode == 200 else {
                let failure: Failure
                switch http.statusCode {
                case 401: failure = .unauthorized
                case 403: failure = .forbidden
                case 429: failure = .throttled
                case 300...399: failure = .redirect
                default: failure = .http
                }
                return .init(checkedAt: clock(), status: .unavailable(failure),
                    retryAfter: failure == .throttled ? retryAfter(http.value(forHTTPHeaderField: "Retry-After"), now: clock()) ?? 60 : nil)
            }
            let result = parse(data, symbol: symbol, limit: limit, maxAgeDays: maxAgeDays, now: now, checkedAt: clock())
            // An echoed credential is never source context, even in a nominally successful response.
            if result.records.contains(where: { record in
                [record.newsItem.title, record.newsItem.snippet, record.newsItem.source,
                 record.newsItem.link?.absoluteString.removingPercentEncoding ?? ""].contains(where: { $0.contains(key) })
            }) { return .init(checkedAt: clock(), status: .unavailable(.malformed)) }
            if let reason = blocked(allowed, isCurrent) { return .init(checkedAt: clock(), status: .unavailable(reason)) }
            return result
        } catch {
            let reason = blocked(allowed, isCurrent) ?? (error as? Failure)
                ?? (error is CancellationError || (error as? URLError)?.code == .cancelled ? .cancelled : .transport)
            return .init(checkedAt: clock(), status: .unavailable(reason))
        }
    }

    private static func blocked(_ allowed: () -> Bool, _ isCurrent: () -> Bool) -> Failure? {
        if Task.isCancelled { return .cancelled }
        if !allowed() { return .policyDenied }
        return isCurrent() ? nil : .configurationChanged
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 12
        return configuration
    }

    /// Streaming enforces the byte cap while receiving, not after an unbounded data(for:) allocation.
    /// A per-operation session is cancelled on every exit, including a refused redirect or byte cap.
    private static func send(_ request: URLRequest, allowed: () -> Bool, isCurrent: () -> Bool) async throws -> (Data, URLResponse) {
        if let reason = blocked(allowed, isCurrent) { throw reason }
        let session = URLSession(configuration: sessionConfiguration(), delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        if let reason = blocked(allowed, isCurrent) { throw reason }
        guard let http = response as? HTTPURLResponse, http.url == request.url else { throw Failure.redirect }
        guard http.statusCode == 200 else { return (Data(), response) } // Do not retain error bodies.
        let data = try await receive(bytes, expectedLength: response.expectedContentLength, allowed: allowed, isCurrent: isCurrent)
        if let reason = blocked(allowed, isCurrent) { throw reason }
        return (data, response)
    }

    /// The exact streaming boundary is also exercised by offline byte sequences.
    static func receive<S: AsyncSequence>(_ bytes: S, expectedLength: Int64,
                                         allowed: () -> Bool, isCurrent: () -> Bool) async throws -> Data where S.Element == UInt8 {
        if let reason = blocked(allowed, isCurrent) { throw reason }
        guard expectedLength <= maximumBytes else { throw Failure.oversized }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw Failure.oversized }
            // Recheck during streaming too, without reading settings once for every byte.
            if data.count % 16_384 == 0, let reason = blocked(allowed, isCurrent) { throw reason }
            data.append(byte)
        }
        if let reason = blocked(allowed, isCurrent) { throw reason }
        return data
    }

    final class NoRedirect: NSObject, URLSessionTaskDelegate {
        nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    nonisolated static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value, value.utf8.count <= 100 else { return nil }
        let text = value.trimmingCharacters(in: .whitespaces)
        if text.range(of: #"\A[0-9]{1,10}\z"#, options: .regularExpression) != nil, let seconds = Double(text) {
            return min(seconds, 3600)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return min(max(0, date.timeIntervalSince(now)), 3600)
    }

    /// Pure parser. A valid [] answers the request; malformed envelopes never do.
    /// Partial arrays retain usable rows and exclusion counts, not discarded source text.
    nonisolated static func parse(_ data: Data, symbol: String, limit: Int = 5,
                                  maxAgeDays: Double = 7, now: Date, checkedAt: Date) -> Observation {
        func failed(_ reason: Failure) -> Observation { .init(checkedAt: checkedAt, status: .unavailable(reason)) }
        guard validBounds(symbol, limit, maxAgeDays, now) else { return failed(.invalidRequest) }
        guard data.count <= maximumBytes else { return failed(.oversized) }
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return failed(.malformed) }
        guard rows.count <= maximumRecords else { return failed(.oversized) }
        var result = Observation(checkedAt: checkedAt, status: .answered)
        var seen: Set<String> = []
        for value in rows {
            guard let row = value as? [String: Any] else { result.excluded.invalid += 1; continue }
            guard let created = publication(row["created"]) else { result.excluded.missingDate += 1; continue }
            if created.date > now { result.excluded.future += 1; continue }
            if created.date < now.addingTimeInterval(-maxAgeDays * 86_400) { result.excluded.stale += 1; continue }
            guard let id = recordID(row["id"]), let rawTitle = row["title"] as? String,
                  let stocks = row["stocks"] as? [[String: Any]],
                  stocks.allSatisfy({ ($0["name"] as? String).map { !$0.isEmpty && $0.utf8.count <= 32 } == true }),
                  optionalString(row["body"]), optionalString(row["teaser"]), optionalString(row["author"]),
                  optionalString(row["url"]) else { result.excluded.invalid += 1; continue }
            guard stocks.contains(where: { ($0["name"] as? String)?.uppercased() == symbol.uppercased() }) else {
                result.excluded.unrelated += 1; continue
            }
            let updated = publication(row["updated"])
            if let raw = row["updated"], !(raw is NSNull), updated == nil {
                result.excluded.invalid += 1; continue
            }
            if let updated, updated.date < created.date { result.excluded.invalid += 1; continue }
            if let updated, updated.date > now { result.excluded.future += 1; continue }
            let title = StockSageNewsService.boundedText(plainText(rawTitle), limit: 240)
            guard !title.isEmpty,
                  let canonical = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else {
                result.excluded.invalid += 1; continue
            }
            // Digest complete records before excerpt caps: revised signs/numbers remain distinct.
            let identity = provider + ":" + SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
            guard seen.insert(identity).inserted else { result.excluded.duplicates += 1; continue }
            let body = plainText(row["body"] as? String ?? "")
            let teaser = plainText(row["teaser"] as? String ?? "")
            let author = StockSageNewsService.boundedText(plainText(row["author"] as? String ?? ""), limit: 80)
            let item = StockSageNewsService.NewsItem(date: created.date, title: title,
                snippet: StockSageNewsService.snippet(from: teaser.isEmpty ? body : teaser), link: safeLink(row["url"]),
                sentiment: nil, source: provider + (author.isEmpty ? "" : " · " + author),
                articleIdentity: identity, publicationTime: created.iso)
            result.records.append(.init(newsItem: item, providerID: id, originalCreated: created.original,
                originalUpdated: updated?.original, updatedAt: updated?.date, hasBody: !body.isEmpty))
        }
        result.records.sort {
            if $0.newsItem.date != $1.newsItem.date { return $0.newsItem.date > $1.newsItem.date }
            return $0.newsItem.id < $1.newsItem.id
        }
        result.excluded.omitted = max(0, result.records.count - limit)
        result.records = Array(result.records.prefix(limit))
        return result
    }

    nonisolated static func validKey(_ key: String) -> Bool {
        (1...512).contains(key.utf8.count) && key.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
    }
    private nonisolated static func validSymbol(_ symbol: String) -> Bool {
        symbol.range(of: #"\A[A-Za-z]{1,10}(?:[.-][A-Za-z])?\z"#, options: .regularExpression) != nil
    }
    private nonisolated static func validBounds(_ symbol: String, _ limit: Int, _ days: Double, _ now: Date) -> Bool {
        validSymbol(symbol) && (1...maximumRecords).contains(limit) && days.isFinite && (0...7).contains(days)
            && now.timeIntervalSince1970.isFinite && (0...253_402_214_400).contains(now.timeIntervalSince1970)
    }
    private nonisolated static func optionalString(_ value: Any?) -> Bool {
        value == nil || value is NSNull || value is String
    }
    private nonisolated static func recordID(_ value: Any?) -> String? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let id = Int64(number.stringValue), id > 0 else { return nil }
        return String(id)
    }
    private nonisolated struct Publication {
        let date: Date
        let original: String
        let iso: String
    }
    /// Strict official RFC-style grammar, numeric timezone, second precision. No guessed zone,
    /// fabricated midnight, lenient calendar rollover, or checked-time replacement.
    private nonisolated static func publication(_ value: Any?) -> Publication? {
        guard let text = value as? String, text.utf8.count == 31,
              text.range(of: #"\A(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun), [0-9]{2} (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} [+-][0-9]{4}\z"#,
                         options: .regularExpression) != nil else { return nil }
        let zone = String(text.suffix(5))
        guard zone != "-0000", let hours = Int(zone.dropFirst().prefix(2)), let minutes = Int(zone.suffix(2)),
              hours <= 14, minutes < 60, hours < 14 || minutes == 0 else { return nil }
        let seconds = (hours * 3600 + minutes * 60) * (zone.first == "-" ? -1 : 1)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: seconds)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        // NewsItem's ISO field keeps the source's offset and second precision, not Date's UTC rendering.
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let iso = formatter.string(from: date) + zone.prefix(3) + ":" + zone.suffix(2)
        return Publication(date: date, original: text, iso: iso)
    }

    nonisolated static func safeLink(_ value: Any?) -> URL? {
        guard let text = value as? String, !text.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 32 }),
              let url = StockSageNewsService.safeLink(text), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              url.port == nil || url.port == 443,
              !(parts.queryItems ?? []).contains(where: { ["token", "api_token", "apikey", "api_key", "key", "authorization"].contains($0.name.lowercased()) }) else { return nil }
        return url
    }

    /// Text-only cleanup; no WebKit/attributed HTML loading, remote assets or link execution.
    /// Unknown entities stay literal. Tags become spaces so markup cannot join numeric tokens.
    nonisolated static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"(?is)<!--.*?(?:-->|\z)|<(script|style)\b[^>]*>.*?(?:</\1\s*>|\z)"#,
            with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
        let pattern = #"&(?:#(?:[xX][0-9a-fA-F]{1,8}|[0-9]{1,10})|[A-Za-z]{2,8});"#
        let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                        "minus": "−", "ndash": "–", "mdash": "—"]
        if let regex = try? NSRegularExpression(pattern: pattern) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let range = Range(match.range, in: text) else { continue }
                let entity = String(text[range].dropFirst().dropLast())
                var replacement = entities[entity]
                if entity.hasPrefix("#") {
                    let hex = entity.lowercased().hasPrefix("#x")
                    if let code = UInt32(entity.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let scalar = UnicodeScalar(code) {
                        replacement = String(scalar)
                    }
                }
                if let replacement { text.replaceSubrange(range, with: replacement) }
            }
        }
        text = text.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.illegalCharacters.contains(scalar)
                || scalar.properties.generalCategory == .format ? " " : String(scalar)
        }.joined()
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
