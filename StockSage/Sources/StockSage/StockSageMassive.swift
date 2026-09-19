import Foundation
import CoreFoundation

/// Massive REST quote source for the US names (pipeline-4 M1, owner decision 2026-09-06).
///
/// VENDOR: Massive (massive.com, formerly Polygon.io — renamed 2025-10-30; `api.polygon.io` and
/// `api.massive.com` are both valid during the transition). Plan Advanced: SIP consolidated tape,
/// unlimited REST, real-time snapshot recency. M1 is REST ONLY — the WebSocket (M3) and Benzinga
/// earnings (M4) are later steps. Missing or unsupported quotes fall back to Yahoo's keyless,
/// typically delayed feed; EODHD is not part of the active quote route.
///
/// ENDPOINT — fetched 2026-09-06 from
/// https://massive.com/docs/rest/stocks/snapshots/full-market-snapshot (+ `.md` mirror):
///   `GET /v2/snapshot/locale/us/markets/stocks/tickers`
///   query `tickers`: "A case-sensitive comma separated list of tickers to get snapshots for. For
///     example, AAPL,TSLA,GOOG. Empty string defaults to querying all tickers."
///   query `include_otc`: "Include OTC securities in the response. Default is false".
///   response: `count`, `status`, `tickers[]` each with `ticker`, `day` {o,h,l,c,v,vw}, `prevDay`
///     {o,h,l,c,v,vw}, `min` {…,t}, `lastTrade` {p,s,t,x,i,c,ds} — "only returned if your current
///     plan includes trades", `lastQuote` {p,P,s,S,t} — "only returned if your current plan includes
///     quotes", `updated` — "The last updated timestamp", `todaysChange`, `todaysChangePerc`,
///     `fmv` (Business plans only).
///   plan recency table: "Stocks Advanced | Real-time"; Starter/Developer "15-minute delayed".
///   NO per-request cap on `tickers` is stated on that page — see `maxTickersPerRequest`.
///
/// TIMESTAMP UNIT: `lastTrade.t` / `lastQuote.t` / `updated` are Unix NANOSECONDS. The page's own
/// field table says only "The last updated timestamp", so the unit is pinned from (a) the page's
/// sample value `1605192894630916600` — 19 digits = 2020-11-12T14:54:54Z in ns, an impossible year
/// in ms or s — and (b) the vendor's trades doc
/// (https://massive.com/docs/rest/stocks/trades-quotes/trades.md): "`sip_timestamp` | The nanosecond
/// accuracy SIP Unix Timestamp." Note `min.t` in the SAME sample is a 13-digit MILLISECOND value
/// (`1684428600000`) — a different unit inside one payload — which is why this parser reads ONLY
/// `lastTrade.t` for `marketTime` and never `min.t`/`updated`.
///
/// AUTH — https://massive.com/docs/rest/quickstart (fetched 2026-09-06): "You can include your API
/// key in two ways: Query String Parameter (e.g., ?apiKey=YOUR_API_KEY)" or "Authorization Header":
/// `GET … HTTP/1.1 / Host: api.massive.com / Authorization: Bearer YOUR_API_KEY`. We use the HEADER
/// so the key never appears in a URL, a log line, or a URL-cache key.
///
/// KEY — by NAME only: `MASSIVE_API_KEY` (the env var the vendor's own https://massive.com/docs/llms.txt
/// names: "Have the user put it in the MASSIVE_API_KEY env var and read it from there") or the
/// Settings field persisted in the device Keychain. Never embedded, never logged.
///
/// HONESTY FLOOR: `marketTime` is the SIP trade timestamp — the existing `freshnessStale` /
/// `StockSageQuoteFreshness` rules decide "Live" vs stale from it (nil ⇒ stale stays). A payload
/// without `lastTrade` (a plan without trades) yields NO quote — never a price lifted from `day.c` —
/// and the symbol falls through to Yahoo's explicitly delayed keyless route, so nothing is
/// silently dropped.
@MainActor
enum StockSageMassive {

    /// Legacy preference name, read only for reversible migration to the device Keychain.
    nonisolated static let keyDefaultsKey = "stocksage.massive." + "key"
    /// Environment-variable NAME the vendor's llms.txt tells clients to read. Name only — never a value.
    nonisolated static let keyEnvName = "MASSIVE_API_KEY"

    /// In-app credential changes invalidate pending evidence, including A→B→A.
    nonisolated static func credentialRevision(_ defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: "stocksage.massive.credentialRevision")
    }
    @discardableResult nonisolated static func setAPIKey(_ value: String, defaults: UserDefaults = .standard,
        storage: StockSageMassiveCredential.Storage = StockSageMassiveCredential.keychain) throws -> Bool {
        try StockSageMassiveCredential.set(value, defaults: defaults, storage: storage)
    }

    nonisolated static let host = "https://api.massive.com"
    nonisolated static let snapshotPath = "/v2/snapshot/locale/us/markets/stocks/tickers"

    /// Offline request-boundary injection; production reads the current persisted access state.
    nonisolated struct Access: Sendable {
        var key: @Sendable () -> String = { StockSageMassive.apiKey }
        var credentialRevision: @Sendable () -> String? = { StockSageMassive.credentialRevision() }
        var policyRevision: @Sendable () -> String? = { AppSettings.policyRevision() }
        var allowed: @Sendable () -> Bool = { ToolPolicy.isExternalAllowed }

        /// A whole request cycle belongs to one access generation, even after A→B→A.
        func capture() -> (key: String, isCurrent: @Sendable () -> Bool) {
            let capturedKey = key()
            let capturedCredential = credentialRevision()
            let capturedPolicy = policyRevision()
            return (capturedKey, {
                !Task.isCancelled && self.allowed() && self.key() == capturedKey &&
                    self.credentialRevision() == capturedCredential && self.policyRevision() == capturedPolicy
            })
        }
    }
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    nonisolated static let snapshotMaximumBytes = 2_000_000
    nonisolated static let historyMaximumBytes = 16_000_000
    nonisolated static let marketMaximumBytes = 50_000_000

    /// Credentials and responses stay outside shared caches, cookies, and redirect handling.
    nonisolated static let restSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: StockSageHTTP.NoRedirect(), delegateQueue: nil)
    }()

    nonisolated static func restTransport(_ request: URLRequest, maximumBytes: Int,
                                         session: URLSession = restSession) async throws -> (Data, URLResponse) {
        try await StockSageHTTP.data(for: request, session: session, maximumBytes: maximumBytes)
    }

    /// Validate injected responses too; final URL identity cannot substitute another resource.
    private nonisolated static func response(for request: URLRequest, maximumBytes: Int,
                                             transport: Transport?) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        if let transport { (data, response) = try await transport(request) }
        else { (data, response) = try await restTransport(request, maximumBytes: maximumBytes) }
        guard let http = response as? HTTPURLResponse, http.url == request.url else {
            throw URLError(.badServerResponse)
        }
        guard data.count <= maximumBytes, response.expectedContentLength <= Int64(maximumBytes) else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        return (data, http)
    }

    /// Settings field first (trimmed), then the `MASSIVE_API_KEY` environment variable; "" when neither
    /// is set. Read on every call so a key typed into Settings takes effect without a restart.
    nonisolated static var apiKey: String {
        // Test hosts use explicit environment/injected fixtures, never the owner's Keychain.
        let environment = ProcessInfo.processInfo.environment[keyEnvName]
        if StockSageStore.isRunningTests { return resolvedKey(saved: nil, environment: environment) }
        return (try? StockSageMassiveCredential.resolve(defaults: .standard,
            storage: StockSageMassiveCredential.keychain, environment: environment)) ?? ""
    }

    nonisolated static func resolvedKey(saved: String?, environment: String?) -> String {
        let saved = saved?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? (environment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") : saved
    }

    /// Whether the Massive path is available at all. With no key the router sends every symbol down
    /// the explicit per-symbol Yahoo fallback unchanged.
    nonisolated static var isConfigured: Bool { !apiKey.isEmpty }

    /// US-equities whitelist: bare alphabetic tickers only; `.SR`, FX, crypto and index markers
    /// are excluded. The curated Nasdaq names match Massive's symbology 1:1; Tadawul is not a
    /// Massive market.
    nonisolated static func covers(_ symbol: String) -> Bool {
        let ticker = symbol.uppercased()
        return !ticker.isEmpty && !ticker.contains(".") && !ticker.contains("=") &&
            !ticker.contains("-") && !ticker.hasPrefix("^") && ticker.allSatisfy(\.isLetter)
    }

    /// Tickers per snapshot request. The v2 full-market-snapshot page states NO cap on `tickers`; the
    /// vendor's sibling unified snapshot (https://massive.com/docs/rest/stocks/snapshots/unified-snapshot.md)
    /// documents "`ticker.any_of` | Comma separated list of tickers, up to a maximum of 250. … Warning:
    /// The maximum number of characters allowed in a URL are subject to your technology stack." 250 is
    /// therefore the only multi-ticker cap the vendor documents anywhere, so it is the chunk size here:
    /// 872 names = ceil(872 / 250) = 4 requests per sweep (vs 872 per-symbol calls today) and every URL
    /// stays under ~1.6 KB. ponytail: revisit only if the v2 page ever documents its own cap.
    nonisolated static let maxTickersPerRequest = 250

    /// Ordered, contiguous chunks of at most `maxTickersPerRequest` — reuses the scan chunker.
    nonisolated static func chunks(_ symbols: [String]) -> [[String]] {
        StockSageScanChunking.chunks(symbols, size: maxTickersPerRequest)
    }

    /// Routing table (pure): with a key, covered symbols go to the batched snapshot path and everything
    /// else stays per-symbol; without a key, everything stays per-symbol. Input order preserved in both.
    nonisolated static func partition(_ symbols: [String], keyPresent: Bool)
        -> (snapshot: [String], perSymbol: [String]) {
        guard keyPresent else { return ([], symbols) }
        var snapshot: [String] = [], perSymbol: [String] = []
        for s in symbols {
            if covers(s) { snapshot.append(s) } else { perSymbol.append(s) }
        }
        return (snapshot, perSymbol)
    }

    /// One snapshot request for ONE chunk. Tickers are uppercased (the endpoint is case-sensitive and
    /// Massive tickers are uppercase); the key rides in the `Authorization` header, never the URL.
    nonisolated static func request(for chunk: [String], key: String) -> URLRequest? {
        guard !key.isEmpty, !chunk.isEmpty, var comps = URLComponents(string: host + snapshotPath) else { return nil }
        comps.queryItems = [URLQueryItem(name: "tickers", value: chunk.map { $0.uppercased() }.joined(separator: ","))]
        guard let url = comps.url else { return nil }
        // Never serve market data from URLSession's cache: a 200 replayed from disk would present
        // an old print as a current one, which is the precise failure the freshness gates exist for.
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return req
    }

    /// Every request a sweep of `symbols` needs — exactly `chunks(symbols).count` of them.
    nonisolated static func requests(for symbols: [String], key: String) -> [URLRequest] {
        chunks(symbols).compactMap { request(for: $0, key: key) }
    }

    /// Unix nanoseconds → Date without going through a single Double (which cannot hold a 19-digit
    /// integer exactly): whole seconds and the sub-second remainder are split as integers first.
    nonisolated static func date(fromNanoseconds ns: Int64) -> Date {
        let seconds = ns / 1_000_000_000
        let remainder = ns % 1_000_000_000
        return Date(timeIntervalSince1970: Double(seconds) + Double(remainder) / 1e9)
    }

    /// Parse one full-market-snapshot payload. Keyed by UPPERCASED ticker; only tickers in
    /// `requestedSymbols` are emitted (the vendor's spelling is replaced by the one WE asked for, as the
    /// Yahoo parser does), so an unrequested extra row can never land on the board. Malformed / missing
    /// `tickers` ⇒ `[:]`.
    static func parseSnapshot(_ data: Data, requestedSymbols: [String])
        -> [String: StockSageQuoteService.LiveQuote] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["tickers"] as? [[String: Any]] else { return [:] }
        var wanted: [String: String] = [:]                       // UPPER → requested spelling (first wins)
        for s in requestedSymbols where wanted[s.uppercased()] == nil {
            // This board has uppercase IDs; native mixed-case securities stay in the exact-ID feed.
            guard StockSageLiveStream.stockSymbol(s) == s.uppercased() else { continue }
            wanted[s.uppercased()] = s
        }
        var out: [String: StockSageQuoteService.LiveQuote] = [:]
        for row in rows {
            guard let ticker = row["ticker"] as? String,
                  let requested = wanted[ticker],
                  let q = parseTicker(row, requestedSymbol: requested) else { continue }
            out[ticker.uppercased()] = q
        }
        return out
    }

    /// One `tickers[]` row → LiveQuote. price ← `lastTrade.p` (> 0, finite; absent ⇒ nil — never `day.c`),
    /// marketTime ← `lastTrade.t` (ns), previousClose ← `prevDay.c`; a missing/non-positive `prevDay.c`
    /// takes the SAME flat-placeholder + `isNewListing` route as the Yahoo parser (L3-08 parity),
    /// never a fabricated 0.00 %.
    static func parseTicker(_ row: [String: Any], requestedSymbol: String)
        -> StockSageQuoteService.LiveQuote? {
        guard let lastTrade = row["lastTrade"] as? [String: Any],
              let price = finite(lastTrade["p"]), price > 0 else { return nil }
        let realPreviousClose = finite((row["prevDay"] as? [String: Any])?["c"]).flatMap { $0 > 0 ? $0 : nil }
        let marketTime = int64(lastTrade["t"]).map(date(fromNanoseconds:))
        return StockSageQuoteService.LiveQuote(symbol: requestedSymbol, price: price,
                                               previousClose: realPreviousClose ?? price,
                                               marketTime: marketTime,
                                               isNewListing: realPreviousClose == nil, priceSource: .massiveSIP,
                                               previousCloseSource: realPreviousClose == nil ? nil : .massiveSIP,
                                               previousCloseQuoteTime: realPreviousClose == nil ? nil : marketTime)
    }

    nonisolated static func finite(_ any: Any?) -> Double? {
        if let n = any as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        let v: Double?
        if let d = any as? Double { v = d }
        else if let i = any as? Int { v = Double(i) }
        else if let s = any as? String { v = Double(s) }
        else { v = nil }
        guard let value = v, value.isFinite else { return nil }
        return value
    }

    /// Int64 first: a 19-digit JSON integer bridges to Int64 exactly, and `as? Double` would REFUSE it
    /// (not exactly representable) — the Double branch only catches a payload that spelled it in
    /// exponent form.
    nonisolated static func int64(_ any: Any?) -> Int64? {
        if let n = any as? NSNumber {
            guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            // Integer JSON spelling first, without rounding through Double. The exact
            // conversion fallback accepts integral exponent forms but never truncates fractions.
            return Int64(n.stringValue) ?? Int64(exactly: n.doubleValue)
        }
        if let s = any as? String { return Int64(s) }
        return nil
    }

    /// Batched fetch: one request per chunk of `maxTickersPerRequest`. A chunk that fails (non-200,
    /// transport error, unparseable) contributes nothing, so its symbols are absent from the result and
    /// the caller's per-symbol Yahoo fallback picks them up — nothing is dropped silently.
    static func fetchSnapshots(for symbols: [String], access: Access = .init(), transport: Transport? = nil) async -> [String: StockSageQuoteService.LiveQuote] {
        guard access.allowed(), !Task.isCancelled, !symbols.isEmpty else { return [:] }
        let captured = access.capture()
        guard !captured.key.isEmpty, captured.isCurrent() else { return [:] }
        var out: [String: StockSageQuoteService.LiveQuote] = [:]
        for chunk in chunks(symbols) {
            guard captured.isCurrent() else { return [:] }
            guard let req = request(for: chunk, key: captured.key) else { continue }
            let result = try? await response(for: req, maximumBytes: snapshotMaximumBytes, transport: transport)
            guard captured.isCurrent() else { return [:] }
            guard let (data, resp) = result, resp.statusCode == 200 else { continue }
            out.merge(parseSnapshot(data, requestedSymbols: chunk)) { _, new in new }
        }
        return captured.isCurrent() ? out : [:]
    }

    // MARK: - Explicit full-market discovery (not an empty watchlist request)

    nonisolated struct MarketCandidate: Sendable {
        let quote: StockSageQuoteService.LiveQuote
        /// Observed daily volume × daily VWAP; research priority only, not a liquidity guarantee.
        let dollarVolume: Double?
    }
    nonisolated struct MarketSnapshot: Sendable {
        let returnedCount: Int
        let rows: [MarketCandidate]
    }

    /// Omit tickers to request the entire provider-returned US listed market. Explicitly no OTC.
    /// Separate from request(for:) so an empty watchlist never accidentally triggers a market sweep.
    nonisolated static func marketRequest(key: String) -> URLRequest? {
        guard !key.isEmpty, var components = URLComponents(string: host + snapshotPath) else { return nil }
        components.queryItems = [URLQueryItem(name: "include_otc", value: "false")]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func parseMarketSnapshot(_ data: Data) -> MarketSnapshot? {
        guard data.count <= marketMaximumBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "OK", let rows = root["tickers"] as? [[String: Any]],
              rows.count <= 50_000 else { return nil }
        if let count = root["count"], int64(count) != Int64(rows.count) { return nil }
        var parsed: [String: MarketCandidate] = [:]
        for row in rows {
            guard let symbol = row["ticker"] as? String, (1...12).contains(symbol.utf8.count),
                  symbol.utf8.allSatisfy({ (65...90).contains($0) }), covers(symbol),
                  let quote = parseTicker(row, requestedSymbol: symbol) else { continue }
            let day = row["day"] as? [String: Any]
            var activity: Double?
            if let volume = finite(day?["v"]), volume >= 0,
               let vwap = finite(day?["vw"]), vwap > 0, (volume * vwap).isFinite {
                activity = volume * vwap
            }
            if let previous = parsed[symbol],
               (previous.quote.marketTime ?? .distantPast) >= (quote.marketTime ?? .distantPast) { continue }
            parsed[symbol] = MarketCandidate(quote: quote, dollarVolume: activity)
        }
        return MarketSnapshot(returnedCount: rows.count, rows: parsed.values.sorted { $0.quote.symbol < $1.quote.symbol })
    }

    static func fetchMarketSnapshot(access: Access = .init(), transport: Transport? = nil) async -> MarketSnapshot? {
        guard access.allowed(), !Task.isCancelled else { return nil }
        let captured = access.capture()
        guard captured.isCurrent(), let request = marketRequest(key: captured.key) else { return nil }
        let result = try? await response(for: request, maximumBytes: marketMaximumBytes, transport: transport)
        guard captured.isCurrent(), let (data, response) = result, response.statusCode == 200 else { return nil }
        return parseMarketSnapshot(data)
    }

    // MARK: - Split-adjusted daily history (M1b)

    /// Massive's documented custom-bars endpoint is the history source for covered US equities.
    /// https://www.massive.com/docs/rest/stocks/aggregates/custom-bars
    /// `GET /v2/aggs/ticker/{ticker}/range/{multiplier}/{timespan}/{from}/{to}` accepts
    /// `adjusted`, `sort`, and `limit`; each result has `o`, `h`, `l`, `c`, `v`, and a Unix
    /// millisecond `t`. `adjusted=true` is the documented default and matches Yahoo's adjusted
    /// daily-chart semantics closely enough for indicators; an unavailable or malformed response
    /// returns nil so the caller uses Yahoo rather than mixing adjustment bases.
    nonisolated static func historyRequest(symbol: String, from: String, to: String, key: String) -> URLRequest? {
        guard !key.isEmpty, covers(symbol),
              let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              var comps = URLComponents(string: host + "/v2/aggs/ticker/\(encoded)/range/1/day/\(from)/\(to)") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "adjusted", value: "true"),
            URLQueryItem(name: "sort", value: "asc"),
            URLQueryItem(name: "limit", value: "50000"),
        ]
        guard let url = comps.url else { return nil }
        // Never serve market data from URLSession's cache: a 200 replayed from disk would present
        // an old print as a current one, which is the precise failure the freshness gates exist for.
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return req
    }

    /// The Yahoo-compatible ranges used by the app. We intentionally decline unsupported ranges
    /// (and all non-daily intervals) so its existing parser remains the fallback rather than
    /// silently serving a differently shaped series.
    nonisolated static func historyDates(for range: String, now: Date = Date()) -> (from: String, to: String)? {
        let components: DateComponents
        switch range {
        case "5d": components = DateComponents(day: -5)
        case "1mo": components = DateComponents(month: -1)
        case "3mo": components = DateComponents(month: -3)
        case "6mo": components = DateComponents(month: -6)
        case "1y": components = DateComponents(year: -1)
        case "2y": components = DateComponents(year: -2)
        case "5y": components = DateComponents(year: -5)
        case "10y": components = DateComponents(year: -10)
        default: return nil
        }
        guard let start = Calendar(identifier: .gregorian).date(byAdding: components, to: now) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return (formatter.string(from: start), formatter.string(from: now))
    }

    /// Converts Massive's split-adjusted daily aggregate payload into the app's one existing
    /// history value. Empty or malformed HTTP-200 bodies are deliberately nil, never an
    /// authoritative empty history; the Yahoo path below can still answer the same request.
    nonisolated static func parseHistory(_ data: Data, symbol: String) -> StockSagePriceHistory? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "OK",
              let rows = root["results"] as? [[String: Any]], !rows.isEmpty else { return nil }
        if let raw = root["ticker"] {
            guard let echoed = raw as? String,
                  echoed == (StockSageLiveStream.stockSymbol(symbol) ?? symbol) else { return nil }
        }
        // Requests require adjusted=true. Older payloads may omit this metadata, but
        // an explicit false or malformed flag must not feed split discontinuities into ATR.
        if let raw = root["adjusted"] {
            guard let adjusted = raw as? NSNumber, CFGetTypeID(adjusted) == CFBooleanGetTypeID(),
                  adjusted.boolValue else { return nil }
        }
        var bars: [(date: Date, open: Double, high: Double, low: Double, close: Double, volume: Double)] = []
        for row in rows {
            guard let ms = int64(row["t"]), ms >= 0,
                  let open = finite(row["o"]), open > 0,
                  let high = finite(row["h"]), high > 0,
                  let low = finite(row["l"]), low > 0,
                  let close = finite(row["c"]), close > 0 else { continue }
            bars.append((Date(timeIntervalSince1970: Double(ms) / 1_000), open, high, low, close,
                         finite(row["v"]) ?? 0))
        }
        let sorted = bars.sorted { $0.date < $1.date }
        guard sorted.count >= 2 else { return nil }
        return StockSagePriceHistory(symbol: symbol,
                                     dates: sorted.map(\.date), opens: sorted.map(\.open),
                                     highs: sorted.map(\.high), lows: sorted.map(\.low),
                                     closes: sorted.map(\.close), volumes: sorted.map(\.volume),
                                     priceSource: .massiveDaily)
    }

    /// Massive first for supported US daily requests; nil leaves the existing Yahoo fallback
    /// completely in charge of indexes, non-US symbols, monthly bars, no-key runs, and failures.
    static func fetchHistory(symbol: String, range: String, interval: String,
        access: Access = .init(), transport: Transport? = nil) async -> StockSagePriceHistory? {
        guard !Task.isCancelled, access.allowed(), interval == "1d",
              let dates = historyDates(for: range) else { return nil }
        let captured = access.capture()
        guard captured.isCurrent(),
              let req = historyRequest(symbol: symbol, from: dates.from, to: dates.to, key: captured.key) else { return nil }
        return await fetchHistory(symbol: symbol, request: req, allowed: captured.isCurrent, transport: transport)
    }

    /// The production daily-history transport boundary, with no credential lookup in injected calls.
    static func fetchHistory(symbol: String, request: URLRequest,
        allowed: @Sendable () -> Bool,
        transport: Transport? = nil
    ) async -> StockSagePriceHistory? {
        guard !Task.isCancelled, allowed() else { return nil }
        let result = try? await response(for: request, maximumBytes: historyMaximumBytes, transport: transport)
        guard !Task.isCancelled, allowed(), let (data, response) = result,
              response.statusCode == 200 else { return nil }
        return parseHistory(data, symbol: symbol)
    }

    /// "Test connection" for Settings: one single-ticker snapshot (AAPL), reported in words. Never echoes
    /// the key. 401/403 wording follows the vendor's own quickstart ("or you get a 401") and the
    /// snapshot page's plan-access table.
    static func probe() async -> String {
        if let reason = ToolPolicy.webToolsDisabledReason() { return reason }
        return await probe(access: .init())
    }

    static func probe(access: Access, transport: Transport? = nil) async -> String {
        let interrupted = "Connection check cancelled or settings changed. Try again."
        guard !Task.isCancelled else { return interrupted }
        guard access.allowed() else { return "Web access is disabled." }
        let captured = access.capture()
        guard captured.isCurrent() else { return interrupted }
        guard !captured.key.isEmpty else { return "No key set — enter your \(keyEnvName) above." }
        guard let req = request(for: ["AAPL"], key: captured.key) else { return "Could not build the request." }
        let result = try? await response(for: req, maximumBytes: snapshotMaximumBytes, transport: transport)
        guard captured.isCurrent() else { return interrupted }
        guard let (data, resp) = result else {
            return "No response — check the network."
        }
        switch resp.statusCode {
        case 200:
            return parseSnapshot(data, requestedSymbols: ["AAPL"]).count == 1
                ? "Connected — HTTP 200, AAPL snapshot parsed."
                : "HTTP 200 but no usable last trade in the payload (plan may not include trades)."
        case 401: return "Rejected — HTTP 401 (key not accepted)."
        case 403: return "Forbidden — HTTP 403 (plan does not include this endpoint)."
        case let code: return "HTTP \(code)."
        }
    }
}
