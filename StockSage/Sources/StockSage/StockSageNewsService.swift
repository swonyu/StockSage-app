import Foundation

/// EODHD news feed — recent headlines for a US symbol, used as CITABLE SOURCES for the optional
/// on-tap catalyst explanation (`StockSageCatalystNarrator`).
///
/// WHY THIS EXISTS: `StockSageCatalystNarrator.facts(for:)` gives the model the engine's own
/// numbers; this service gives it a second, independently-sourced kind of fact — a short list of
/// recent, dated news items the model may cite as "[n] ..." instead of talking from memory. It is
/// not a signal and carries no judgment of its own: parsing is a pure split of the vendor payload
/// into (date, title, a 1-2 sentence snippet, link, an optional sentiment score).
///
/// SOURCE: EODHD's `/api/news` endpoint — `https://eodhd.com/api/news?s=<SYM>.US&limit=5&api_token=…`
/// — the same authenticated feed and key attachment as `StockSageEODHD`'s quotes.
///
/// COST (recorded against the 100k/day EODHD allowance — see HANDOFF.md): EODHD's News API is
/// billed 5 API calls per request PLUS 5 more per ticker named in the request, so one call for one
/// symbol here spends 10 calls, separate from the quote path's per-symbol cost.
///
/// SCOPE: US only, via `StockSageEODHD.covers(symbol)` — the same whitelist the quote feed uses.
///
/// Never throws: `recentNews(for:)` returns `[]` on ANY failure (policy off, non-US symbol, no
/// key, network error, malformed payload) — an empty result means "nothing to show", never "no
/// news exists".
enum StockSageNewsService {

    struct NewsItem: Sendable, Equatable, Identifiable {
        let date: Date
        let title: String
        /// 1-2 sentence snippet derived from the vendor's full `content` field — never the whole
        /// body (a long or paywalled article body is not something this app is licensed to show).
        let snippet: String
        let link: URL?
        /// EODHD's own sentiment polarity, when the payload carries one. Nil is common (most rows
        /// omit it) and is not an error.
        let sentiment: Double?

        nonisolated var id: String { "\(date.timeIntervalSince1970)|\(title)" }
    }

    nonisolated static let caveat =
        "EODHD news — headlines and short snippets, not verified analysis. Absence of an item "
        + "here is not evidence that nothing happened."

    /// Recent news for a US symbol, newest first, within the freshness cutoff (`maxAgeDays`).
    /// `[]` — never throws — when external access is off, the symbol is not US-covered
    /// (`StockSageEODHD.covers`), the key is missing, or the feed is unreachable/malformed.
    static func recentNews(for symbol: String, limit: Int = 5, maxAgeDays: Double = 7,
                           now: Date = Date()) async -> [NewsItem] {
        guard ToolPolicy.isExternalAllowed, StockSageEODHD.covers(symbol) else { return [] }
        let key = StockSageEODHD.apiKey
        guard !key.isEmpty,
              let url = URL(string: "https://eodhd.com/api/news?s=\(StockSageEODHD.eodhdSymbol(symbol))"
                + "&limit=\(limit)&api_token=\(key)&fmt=json")
        else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return parseNews(raw, limit: limit, maxAgeDays: maxAgeDays, now: now)
    }

    /// Pure parse of the vendor's array-of-objects payload — no network, unit-testable. Skips any
    /// row missing a usable date or title, and drops rows older than `maxAgeDays`.
    nonisolated static func parseNews(_ raw: [[String: Any]], limit: Int = 5, maxAgeDays: Double = 7,
                                      now: Date = Date()) -> [NewsItem] {
        let cutoff = now.addingTimeInterval(-maxAgeDays * 86_400)
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        var out: [NewsItem] = []
        for row in raw {
            guard let dateStr = row["date"] as? String,
                  let date = withFraction.date(from: dateStr) ?? plain.date(from: dateStr)
            else { continue }
            guard date >= cutoff else { continue }               // straddle: date == cutoff passes ("≤7 days")
            guard let title = row["title"] as? String, !title.isEmpty else { continue }
            let link = (row["link"] as? String).flatMap(URL.init(string:))
            let sentimentObj = row["sentiment"] as? [String: Any]
            let sentiment = (sentimentObj?["polarity"] as? Double)
                ?? (sentimentObj?["polarity"] as? Int).map(Double.init)
            out.append(NewsItem(date: date, title: title,
                                snippet: snippet(from: row["content"] as? String ?? ""),
                                link: link, sentiment: sentiment))
        }
        return Array(out.sorted { $0.date > $1.date }.prefix(limit))
    }

    /// 1-2 sentence truncation of a full article body — splits on ". " and keeps at most 2
    /// sentences. Pure and deterministic so a test can pin exact output.
    nonisolated static func snippet(from content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let sentences = trimmed.components(separatedBy: ". ")
        let kept = sentences.prefix(2).joined(separator: ". ")
        if sentences.count <= 2 { return kept }
        return kept.hasSuffix(".") ? kept : kept + "."
    }
}
