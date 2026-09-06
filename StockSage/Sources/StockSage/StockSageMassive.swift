import Foundation

/// Massive REST quote source for the US names (pipeline-4 M1, owner decision 2026-09-06).
///
/// VENDOR: Massive (massive.com, formerly Polygon.io — renamed 2025-10-30; `api.polygon.io` and
/// `api.massive.com` are both valid during the transition). Plan Advanced: SIP consolidated tape,
/// unlimited REST, real-time snapshot recency. M1 is REST ONLY — the WebSocket (M3) and Benzinga
/// earnings (M4) are later steps, and EODHD stays wired as the per-symbol fallback until M5 flips
/// the default (agent-docs/COVERAGE_DESIGN_2026-09-06.md, "Pipeline 4").
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
/// Settings field persisted under UserDefaults `keyDefaultsKey`. Never embedded, never logged.
///
/// HONESTY FLOOR: `marketTime` is the SIP trade timestamp — the existing `freshnessStale` /
/// `StockSageQuoteFreshness` rules decide "Live" vs stale from it (nil ⇒ stale stays). A payload
/// without `lastTrade` (a plan without trades) yields NO quote — never a price lifted from `day.c` —
/// and the symbol falls through to EODHD, then Yahoo, so nothing is silently dropped.
@MainActor
enum StockSageMassive {

    /// UserDefaults key behind the Settings field (both platforms): "stocksage.massive" + ".key".
    nonisolated static let keyDefaultsKey = "stocksage.massive." + "key"
    /// Environment-variable NAME the vendor's llms.txt tells clients to read. Name only — never a value.
    nonisolated static let keyEnvName = "MASSIVE_API_KEY"

    nonisolated static let host = "https://api.massive.com"
    nonisolated static let snapshotPath = "/v2/snapshot/locale/us/markets/stocks/tickers"

    /// Settings field first (trimmed), then the `MASSIVE_API_KEY` environment variable; "" when neither
    /// is set. Read on every call so a key typed into Settings takes effect without a restart.
    nonisolated static var apiKey: String {
        let fromSettings = UserDefaults.standard.string(forKey: keyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fromSettings.isEmpty { return fromSettings }
        return ProcessInfo.processInfo.environment[keyEnvName]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Whether the Massive path is available at all. With no key the router sends every symbol down
    /// the existing per-symbol EODHD → Yahoo chain unchanged.
    nonisolated static var isConfigured: Bool { !apiKey.isEmpty }

    /// Same US-equities whitelist as `StockSageEODHD.covers` (bare alphabetic ticker; `.SR`/FX/crypto/
    /// index markers excluded) — the 872 `nasdaqListed` names match Massive's symbology 1:1 (design doc
    /// "Symbol mapping": zero dotted class-share tickers in the allowlist), and Tadawul is not a Massive
    /// market. One rule, one owner: this is a pure delegate, not a second copy that could drift.
    nonisolated static func covers(_ symbol: String) -> Bool { StockSageEODHD.covers(symbol) }

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
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
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
    /// EODHD parser does), so an unrequested extra row can never land on the board. Malformed / missing
    /// `tickers` ⇒ `[:]`.
    static func parseSnapshot(_ data: Data, requestedSymbols: [String])
        -> [String: StockSageQuoteService.LiveQuote] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["tickers"] as? [[String: Any]] else { return [:] }
        var wanted: [String: String] = [:]                       // UPPER → requested spelling (first wins)
        for s in requestedSymbols where wanted[s.uppercased()] == nil { wanted[s.uppercased()] = s }
        var out: [String: StockSageQuoteService.LiveQuote] = [:]
        for row in rows {
            guard let ticker = row["ticker"] as? String,
                  let requested = wanted[ticker.uppercased()],
                  let q = parseTicker(row, requestedSymbol: requested) else { continue }
            out[ticker.uppercased()] = q
        }
        return out
    }

    /// One `tickers[]` row → LiveQuote. price ← `lastTrade.p` (> 0, finite; absent ⇒ nil — never `day.c`),
    /// marketTime ← `lastTrade.t` (ns), previousClose ← `prevDay.c`; a missing/non-positive `prevDay.c`
    /// takes the SAME flat-placeholder + `isNewListing` route as the EODHD/Yahoo parsers (L3-08 parity),
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
                                               isNewListing: realPreviousClose == nil)
    }

    private nonisolated static func finite(_ any: Any?) -> Double? {
        let v: Double?
        if let d = any as? Double { v = d } else if let i = any as? Int { v = Double(i) } else { v = nil }
        guard let value = v, value.isFinite else { return nil }
        return value
    }

    /// Int64 first: a 19-digit JSON integer bridges to Int64 exactly, and `as? Double` would REFUSE it
    /// (not exactly representable) — the Double branch only catches a payload that spelled it in
    /// exponent form.
    private nonisolated static func int64(_ any: Any?) -> Int64? {
        if let n = any as? Int64 { return n }
        if let n = any as? Int { return Int64(n) }
        if let d = any as? Double, d.isFinite, d >= 0, d < 9.2e18 { return Int64(d) }
        return nil
    }

    /// Batched fetch: one request per chunk of `maxTickersPerRequest`. A chunk that fails (non-200,
    /// transport error, unparseable) contributes nothing, so its symbols are absent from the result and
    /// the caller's per-symbol EODHD → Yahoo chain picks them up — nothing is dropped silently.
    static func fetchSnapshots(for symbols: [String]) async -> [String: StockSageQuoteService.LiveQuote] {
        guard ToolPolicy.isExternalAllowed, !symbols.isEmpty else { return [:] }
        let key = apiKey
        guard !key.isEmpty else { return [:] }
        var out: [String: StockSageQuoteService.LiveQuote] = [:]
        for chunk in chunks(symbols) {
            guard let req = request(for: chunk, key: key),
                  let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
            out.merge(parseSnapshot(data, requestedSymbols: chunk)) { _, new in new }
        }
        return out
    }

    /// "Test connection" for Settings: one single-ticker snapshot (AAPL), reported in words. Never echoes
    /// the key. 401/403 wording follows the vendor's own quickstart ("or you get a 401") and the
    /// snapshot page's plan-access table.
    static func probe() async -> String {
        if let reason = ToolPolicy.webToolsDisabledReason() { return reason }
        let key = apiKey
        guard !key.isEmpty else { return "No key set — enter your \(keyEnvName) above." }
        guard let req = request(for: ["AAPL"], key: key) else { return "Could not build the request." }
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
            return "No response — check the network."
        }
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
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
